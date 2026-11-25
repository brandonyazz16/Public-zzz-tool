// The app window: the real website, shown by CEF (Chromium Embedded Framework, Chrome's
// engine - not Edge, not WebView2) through CEF's C API.
//
// Privacy: everything is local. The page loads from site/index.html, Chrome's background
// services are switched off, crash reports stay off, and all web traffic is pointed at a
// dead local address, so nothing can leave the PC even by accident.

#define CEF_API_VERSION 15600
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_resource_handler_capi.h"
#include "include/capi/cef_response_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/capi/cef_task_capi.h"
#include <stdlib.h>

// ---------------------------------------------------------------- ref counting
// Every object here lives for the whole run (static), so reference counting is a no-op.
static void CEF_CALLBACK rc_add(cef_base_ref_counted_t* self) { (void)self; }
static int CEF_CALLBACK rc_release(cef_base_ref_counted_t* self) { (void)self; return 0; }
static int CEF_CALLBACK rc_one(cef_base_ref_counted_t* self) { (void)self; return 1; }
static int CEF_CALLBACK rc_atleast(cef_base_ref_counted_t* self) { (void)self; return 1; }
static void init_base(cef_base_ref_counted_t* b, size_t size) {
    b->size = size;
    b->add_ref = rc_add;
    b->release = rc_release;
    b->has_one_ref = rc_one;
    b->has_at_least_one_ref = rc_atleast;
}
// Objects CEF passes to us carry a reference we must give back.
#define RELEASE(obj) do { if (obj) (obj)->base.release(&(obj)->base); } while (0)

static void set_str(cef_string_t* s, const char* utf8) {
    cef_string_utf8_to_utf16(utf8, strlen(utf8), s);
}

// ---------------------------------------------------------------- state
static char g_url[4096];
static char g_zoom_file[2048];
static char g_place_file[2048];
static double g_zoom = 0.0; // CEF zoom level: 1.2^level = scale
static int g_zoom_set = 0;

// Chrome's zoom steps (percent).
static const int k_steps[] = { 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200 };
static double level_for(int pct) { return log(pct / 100.0) / log(1.2); }
static int step_index(double level) {
    int best = 0;
    double pct = pow(1.2, level) * 100.0, d = 1e9;
    for (int i = 0; i < (int)(sizeof k_steps / sizeof k_steps[0]); i++) {
        double e = fabs(k_steps[i] - pct);
        if (e < d) { d = e; best = i; }
    }
    return best;
}
static void save_zoom(void) {
    FILE* f = fopen(g_zoom_file, "wb");
    if (f) { fprintf(f, "%d", k_steps[step_index(g_zoom)]); fclose(f); }
}
static void load_zoom(void) {
    int pct = 110; // a little bigger than the site at 100%
    FILE* f = fopen(g_zoom_file, "rb");
    if (f) { int v; if (fscanf(f, "%d", &v) == 1 && v >= 25 && v <= 500) pct = v; fclose(f); }
    g_zoom = level_for(pct);
}

// ---------------------------------------------------------------- zzz://app/ - the app's own address
// The site's files and the app's tools (Check file, Game save, remielle.exe data) are served
// from zzz://app/. It's not a network address: requests never leave the app.
// Every request is answered by main.zig (zapi_handle) on a background thread; the few that
// open a Windows file picker run on the window's thread.

// implemented in api.zig
extern int zapi_handle(const char* path, size_t path_len, const char* body, size_t body_len,
                       char** out, size_t* out_len, const char** mime);
extern void zapi_free(char* p, size_t len);
extern int zapi_needs_ui_thread(const char* path, size_t path_len);

typedef struct {
    cef_resource_handler_t h;
    volatile long refs;
    char* path; size_t path_len;
    char* body; size_t body_len;
    char* out; size_t out_len; size_t sent;
    const char* mime;
    int status;
    cef_callback_t* cb;
} req_t;

static void CEF_CALLBACK req_add(cef_base_ref_counted_t* b) { InterlockedIncrement(&((req_t*)b)->refs); }
static int CEF_CALLBACK req_release(cef_base_ref_counted_t* b) {
    req_t* r = (req_t*)b;
    if (InterlockedDecrement(&r->refs) == 0) {
        free(r->path); free(r->body);
        if (r->out) zapi_free(r->out, r->out_len);
        free(r);
        return 1;
    }
    return 0;
}
static int CEF_CALLBACK req_one(cef_base_ref_counted_t* b) { return ((req_t*)b)->refs == 1; }
static int CEF_CALLBACK req_atleast(cef_base_ref_counted_t* b) { return ((req_t*)b)->refs >= 1; }

typedef struct { cef_task_t t; volatile long refs; req_t* r; } task_t;
static void CEF_CALLBACK task_add(cef_base_ref_counted_t* b) { InterlockedIncrement(&((task_t*)b)->refs); }
static int CEF_CALLBACK task_release(cef_base_ref_counted_t* b) {
    task_t* t = (task_t*)b;
    if (InterlockedDecrement(&t->refs) == 0) { RELEASE(&t->r->h); free(t); return 1; }
    return 0;
}
static int CEF_CALLBACK task_one(cef_base_ref_counted_t* b) { return ((task_t*)b)->refs == 1; }
static int CEF_CALLBACK task_atleast(cef_base_ref_counted_t* b) { return ((task_t*)b)->refs >= 1; }
static void CEF_CALLBACK task_run(cef_task_t* self) {
    req_t* r = ((task_t*)self)->r;
    r->status = zapi_handle(r->path, r->path_len, r->body, r->body_len, &r->out, &r->out_len, &r->mime);
    cef_callback_t* cb = r->cb;
    r->cb = NULL;
    if (cb) { cb->cont(cb); RELEASE(cb); }
}

static char* to_utf8(const cef_string_t* s, size_t* len) {
    cef_string_utf8_t u = {0};
    cef_string_utf16_to_utf8(s->str, s->length, &u);
    char* out = (char*)malloc(u.length + 1);
    memcpy(out, u.str ? u.str : "", u.length);
    out[u.length] = 0;
    *len = u.length;
    cef_string_utf8_clear(&u);
    return out;
}

static int CEF_CALLBACK req_open(cef_resource_handler_t* self, cef_request_t* request, int* handle_request, cef_callback_t* callback) {
    req_t* r = (req_t*)self;
    // path: everything after zzz://app
    cef_string_userfree_t url = request->get_url(request);
    size_t ulen = 0;
    char* u = to_utf8(url, &ulen);
    cef_string_userfree_free(url);
    const char* p = strstr(u, "://");
    p = p ? strchr(p + 3, '/') : NULL;
    if (!p) p = "/";
    r->path_len = strlen(p);
    r->path = (char*)malloc(r->path_len + 1);
    memcpy(r->path, p, r->path_len + 1);
    free(u);
    // body (POST)
    cef_post_data_t* pd = request->get_post_data(request);
    if (pd) {
        size_t n = pd->get_element_count(pd);
        if (n > 0) {
            cef_post_data_element_t** els = (cef_post_data_element_t**)calloc(n, sizeof *els);
            pd->get_elements(pd, &n, els);
            size_t total = 0;
            for (size_t i = 0; i < n; i++) total += els[i]->get_bytes_count(els[i]);
            r->body = (char*)malloc(total + 1);
            size_t at = 0;
            for (size_t i = 0; i < n; i++) {
                at += els[i]->get_bytes(els[i], total - at, r->body + at);
                RELEASE(els[i]);
            }
            r->body_len = at;
            free(els);
        }
        RELEASE(pd);
    }
    RELEASE(request);
    // answer on a background thread (or the window's thread for file pickers)
    r->cb = callback;
    task_t* t = (task_t*)calloc(1, sizeof *t);
    t->t.base.size = sizeof t->t;
    t->t.base.add_ref = task_add;
    t->t.base.release = task_release;
    t->t.base.has_one_ref = task_one;
    t->t.base.has_at_least_one_ref = task_atleast;
    t->t.execute = task_run;
    t->refs = 1;
    t->r = r;
    r->h.base.add_ref(&r->h.base); // the task holds the request until it has run
    cef_post_task(zapi_needs_ui_thread(r->path, r->path_len) ? TID_UI : TID_FILE_USER_BLOCKING, &t->t);
    *handle_request = 0; // answered later, when the task calls callback->cont()
    return 1;
}

static void header(cef_response_t* resp, const char* name, const char* value) {
    cef_string_t n = {0}, v = {0};
    set_str(&n, name);
    set_str(&v, value);
    resp->set_header_by_name(resp, &n, &v, 1);
    cef_string_clear(&n);
    cef_string_clear(&v);
}

static void CEF_CALLBACK req_headers(cef_resource_handler_t* self, cef_response_t* resp, int64_t* len, cef_string_t* redirect) {
    (void)redirect;
    req_t* r = (req_t*)self;
    resp->set_status(resp, r->status ? r->status : 500);
    // CEF wants the bare type ("text/html") and the charset separately - a combined
    // "text/html; charset=utf-8" makes it show the page as plain text.
    const char* mime = r->mime ? r->mime : "application/octet-stream";
    char type[128];
    const char* semi = strchr(mime, ';');
    size_t tl = semi ? (size_t)(semi - mime) : strlen(mime);
    if (tl >= sizeof type) tl = sizeof type - 1;
    memcpy(type, mime, tl);
    type[tl] = 0;
    cef_string_t m = {0};
    set_str(&m, type);
    resp->set_mime_type(resp, &m);
    cef_string_clear(&m);
    if (semi && strstr(semi, "utf-8")) {
        cef_string_t cs = {0};
        set_str(&cs, "utf-8");
        resp->set_charset(resp, &cs);
        cef_string_clear(&cs);
    }
    header(resp, "Cache-Control", "no-store");
    *len = (int64_t)r->out_len;
    RELEASE(resp);
}

static int CEF_CALLBACK req_read(cef_resource_handler_t* self, void* out, int want, int* got, cef_resource_read_callback_t* cb) {
    req_t* r = (req_t*)self;
    RELEASE(cb);
    size_t left = r->out_len - r->sent;
    if (left == 0) { *got = 0; return 0; }
    size_t n = left < (size_t)want ? left : (size_t)want;
    memcpy(out, r->out + r->sent, n);
    r->sent += n;
    *got = (int)n;
    return 1;
}

static void CEF_CALLBACK req_cancel(cef_resource_handler_t* self) { (void)self; }

static cef_resource_handler_t* CEF_CALLBACK scheme_create(cef_scheme_handler_factory_t* self, cef_browser_t* browser, cef_frame_t* frame,
                                                          const cef_string_t* scheme, cef_request_t* request) {
    (void)self; (void)scheme;
    RELEASE(browser);
    RELEASE(frame);
    RELEASE(request);
    req_t* r = (req_t*)calloc(1, sizeof *r);
    r->h.base.size = sizeof r->h;
    r->h.base.add_ref = req_add;
    r->h.base.release = req_release;
    r->h.base.has_one_ref = req_one;
    r->h.base.has_at_least_one_ref = req_atleast;
    r->h.open = req_open;
    r->h.get_response_headers = req_headers;
    r->h.read = req_read;
    r->h.cancel = req_cancel;
    r->refs = 1;
    return &r->h;
}
static cef_scheme_handler_factory_t g_factory;

// ---------------------------------------------------------------- app
static cef_app_t g_app;

// zzz:// is registered in every process (renderer included), as a secure, fetch-able scheme.
static void CEF_CALLBACK on_register_custom_schemes(cef_app_t* self, cef_scheme_registrar_t* reg) {
    (void)self;
    cef_string_t name = {0};
    set_str(&name, "zzz");
    reg->add_custom_scheme(reg, &name, CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE | CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED);
    cef_string_clear(&name);
    // the registrar is only valid during this call; it isn't ref-counted
}

static void CEF_CALLBACK on_before_command_line_processing(cef_app_t* self, const cef_string_t* process_type, cef_command_line_t* cl) {
    (void)self;
    if (process_type && process_type->length) { RELEASE(cl); return; }
    static const char* switches[] = {
        "disable-background-networking", "disable-component-update", "disable-domain-reliability",
        "disable-breakpad", "disable-crash-reporter", "no-pings", "disable-sync", "metrics-recording-only",
        "disable-default-apps", "no-first-run", "disable-client-side-phishing-detection",
    };
    for (size_t i = 0; i < sizeof switches / sizeof switches[0]; i++) {
        cef_string_t s = {0};
        set_str(&s, switches[i]);
        cl->append_switch(cl, &s);
        cef_string_clear(&s);
    }
    // Nothing goes online: every http/https request goes to a closed local port.
    cef_string_t k = {0}, v = {0};
    set_str(&k, "proxy-server");
    set_str(&v, "http://127.0.0.1:9");
    cl->append_switch_with_value(cl, &k, &v);
    cef_string_clear(&k);
    cef_string_clear(&v);
    RELEASE(cl);
}

// ---------------------------------------------------------------- client + handlers
static cef_client_t g_client;
static cef_life_span_handler_t g_life;
static cef_download_handler_t g_dl;
static cef_keyboard_handler_t g_keys;
static cef_load_handler_t g_load;
static cef_display_handler_t g_display;

static cef_life_span_handler_t* CEF_CALLBACK get_life(cef_client_t* s) { (void)s; return &g_life; }
static cef_download_handler_t* CEF_CALLBACK get_dl(cef_client_t* s) { (void)s; return &g_dl; }
static cef_keyboard_handler_t* CEF_CALLBACK get_keys(cef_client_t* s) { (void)s; return &g_keys; }
static cef_load_handler_t* CEF_CALLBACK get_load(cef_client_t* s) { (void)s; return &g_load; }
static cef_display_handler_t* CEF_CALLBACK get_display(cef_client_t* s) { (void)s; return &g_display; }

// Closing the window ends the app.
static cef_browser_t* g_browser; // kept from on_after_created until on_before_close
static void CEF_CALLBACK on_before_close(cef_life_span_handler_t* self, cef_browser_t* browser) {
    (void)self;
    if (g_browser) { RELEASE(g_browser); g_browser = NULL; }
    RELEASE(browser);
    cef_quit_message_loop();
}
// Links that try to open a new window open nothing (the site is all one page).
// Links. Web links (http / https) open in your own browser - the app window itself never goes
// online. Links to the app's own pages (zzz://app/...) open in the app window.
static int is_web(const cef_string_t* u) {
    if (!u || !u->str) return 0;
    const wchar_t* w = (const wchar_t*)u->str;
    return (u->length > 7 && _wcsnicmp(w, L"http://", 7) == 0) || (u->length > 8 && _wcsnicmp(w, L"https://", 8) == 0);
}
static void open_in_browser(const cef_string_t* u) {
    wchar_t buf[2048];
    size_t n = u->length < 2047 ? u->length : 2047;
    memcpy(buf, u->str, n * sizeof(wchar_t));
    buf[n] = 0;
    ShellExecuteW(NULL, L"open", buf, NULL, NULL, SW_SHOWNORMAL);
}

static int CEF_CALLBACK on_before_popup(cef_life_span_handler_t* self, cef_browser_t* browser, cef_frame_t* frame,
                                        int popup_id, const cef_string_t* target_url, const cef_string_t* target_frame_name,
                                        cef_window_open_disposition_t target_disposition, int user_gesture,
                                        const cef_popup_features_t* popup_features, cef_window_info_t* window_info,
                                        cef_client_t** client, cef_browser_settings_t* settings,
                                        cef_dictionary_value_t** extra_info, int* no_javascript_access) {
    (void)self; (void)popup_id; (void)target_frame_name; (void)target_disposition;
    (void)popup_features; (void)window_info; (void)client; (void)settings; (void)extra_info; (void)no_javascript_access;
    if (target_url && target_url->length > 0) {
        if (is_web(target_url)) {
            if (user_gesture) open_in_browser(target_url); // only links you clicked
        } else if (target_url->length > 10 && _wcsnicmp((const wchar_t*)target_url->str, L"zzz://app/", 10) == 0) {
            cef_frame_t* main = browser->get_main_frame(browser);
            if (main) { main->load_url(main, target_url); RELEASE(main); }
        }
    }
    RELEASE(browser);
    RELEASE(frame);
    return 1; // never a second window
}

// A web link clicked inside the page (no new tab): your browser too.
static int CEF_CALLBACK on_before_browse(cef_request_handler_t* self, cef_browser_t* browser, cef_frame_t* frame,
                                        cef_request_t* request, int user_gesture, int is_redirect) {
    (void)self; (void)is_redirect;
    int cancel = 0;
    cef_string_userfree_t u = request->get_url(request);
    if (u && is_web(u)) {
        if (user_gesture) open_in_browser(u);
        cancel = 1; // the window stays on the app's pages
    }
    if (u) cef_string_userfree_free(u);
    RELEASE(request);
    RELEASE(frame);
    RELEASE(browser);
    return cancel;
}
static cef_request_handler_t g_req_handler;
static cef_request_handler_t* CEF_CALLBACK get_req_handler(cef_client_t* s) { (void)s; return &g_req_handler; }

// Downloads ("Download all saves (.json)") ask where to save, like Chrome.
static int CEF_CALLBACK can_download(cef_download_handler_t* self, cef_browser_t* browser, const cef_string_t* url, const cef_string_t* method) {
    (void)self; (void)url; (void)method;
    RELEASE(browser);
    return 1;
}
static int CEF_CALLBACK on_before_download(cef_download_handler_t* self, cef_browser_t* browser, cef_download_item_t* item,
                                           const cef_string_t* suggested_name, cef_before_download_callback_t* cb) {
    (void)self;
    cef_string_t empty = {0};
    (void)suggested_name;
    cb->cont(cb, &empty, 1); // 1 = show the Save As dialog with the suggested name
    RELEASE(cb);
    RELEASE(item);
    RELEASE(browser);
    return 1;
}
static void CEF_CALLBACK on_download_updated(cef_download_handler_t* self, cef_browser_t* browser, cef_download_item_t* item,
                                             cef_download_item_callback_t* cb) {
    (void)self;
    RELEASE(cb);
    RELEASE(item);
    RELEASE(browser);
}

static void apply_zoom(cef_browser_t* browser) {
    cef_browser_host_t* host = browser->get_host(browser);
    if (host) { host->set_zoom_level(host, g_zoom); RELEASE(host); }
}

// Ctrl +, Ctrl -, Ctrl 0 zoom like a browser; F5 reloads; F12 opens nothing (no dev tools).
static int CEF_CALLBACK on_pre_key_event(cef_keyboard_handler_t* self, cef_browser_t* browser, const cef_key_event_t* e,
                                         cef_event_handle_t os_event, int* is_keyboard_shortcut) {
    (void)self; (void)os_event; (void)is_keyboard_shortcut;
    int handled = 0;
    if (e->type == KEYEVENT_RAWKEYDOWN && (e->modifiers & EVENTFLAG_CONTROL_DOWN)) {
        int i = step_index(g_zoom);
        int key = e->windows_key_code;
        int n = (int)(sizeof k_steps / sizeof k_steps[0]);
        if (key == VK_OEM_PLUS || key == VK_ADD) { if (i + 1 < n) i++; handled = 1; }
        else if (key == VK_OEM_MINUS || key == VK_SUBTRACT) { if (i > 0) i--; handled = 1; }
        else if (key == '0' || key == VK_NUMPAD0) { i = 6; handled = 1; }
        if (handled) {
            g_zoom = level_for(k_steps[i]);
            apply_zoom(browser);
            save_zoom();
        }
    } else if (e->type == KEYEVENT_RAWKEYDOWN && e->windows_key_code == VK_F5) {
        browser->reload(browser);
        handled = 1;
    }
    RELEASE(browser);
    return handled;
}

// The zoom level is set once the page has loaded (Chrome keeps it per page after that).
// Inside the app every page also loads app_pages/app-inject.js: the "App tools" link, the
// .zon editor's "Pack into game" button and Ctrl + mouse wheel zoom (the website itself
// doesn't have any of these).
static const char* k_inject_js =
    "(function(){if(location.protocol!=='zzz:'||document.getElementById('zzzAppInject'))return;"
    "var s=document.createElement('script');s.id='zzzAppInject';s.src='/app-inject.js';document.head.appendChild(s);})();";

static void CEF_CALLBACK on_load_end(cef_load_handler_t* self, cef_browser_t* browser, cef_frame_t* frame, int status) {
    (void)self; (void)status;
    if (frame && frame->is_main(frame)) {
        cef_string_t code = {0}, url = {0};
        set_str(&code, k_inject_js);
        frame->execute_java_script(frame, &code, &url, 0);
        cef_string_clear(&code);
    }
    if (frame && frame->is_main(frame) && !g_zoom_set) { apply_zoom(browser); g_zoom_set = 1; }
    RELEASE(frame);
    RELEASE(browser);
}

// ---------------------------------------------------------------- the window: icon, title, size


static HWND top_window(cef_browser_t* browser) {
    cef_browser_host_t* host = browser->get_host(browser);
    if (!host) return NULL;
    HWND h = host->get_window_handle(host);
    RELEASE(host);
    return h ? GetAncestor(h, GA_ROOT) : NULL;
}

// The page's title after the app's name: "ZZZ .zon Tool - App tools".
static void CEF_CALLBACK on_title_change(cef_display_handler_t* self, cef_browser_t* browser, const cef_string_t* title) {
    (void)self;
    HWND w = top_window(browser);
    if (w) {
        wchar_t buf[512];
        int n = 0;
        if (title && title->length > 0) {
            n = _snwprintf(buf, 511, L"ZZZ .zon Tool — %.*s", (int)(title->length > 400 ? 400 : title->length), (const wchar_t*)title->str);
        }
        if (n <= 0) wcscpy(buf, L"ZZZ .zon Tool");
        buf[511] = 0;
        SetWindowTextW(w, buf);
    }
    RELEASE(browser);
}

// Window size and position, remembered in zzz-zon-tool-data/window.txt:
// "left top right bottom maximized" (Windows' own "normal" position).
static int load_place(RECT* rc, int* maxed) {
    FILE* f = fopen(g_place_file, "rb");
    if (!f) return 0;
    long l, t, r, b;
    int m = 0;
    int ok = fscanf(f, "%ld %ld %ld %ld %d", &l, &t, &r, &b, &m) == 5;
    fclose(f);
    if (!ok || r - l < 300 || b - t < 200) return 0;
    rc->left = l; rc->top = t; rc->right = r; rc->bottom = b;
    *maxed = m;
    // only if it's still on a screen (a monitor may have been unplugged)
    return MonitorFromRect(rc, MONITOR_DEFAULTTONULL) != NULL;
}
static void save_place(HWND w) {
    WINDOWPLACEMENT wp;
    memset(&wp, 0, sizeof wp);
    wp.length = sizeof wp;
    if (!GetWindowPlacement(w, &wp)) return;
    FILE* f = fopen(g_place_file, "wb");
    if (!f) return;
    RECT r = wp.rcNormalPosition;
    fprintf(f, "%ld %ld %ld %ld %d", (long)r.left, (long)r.top, (long)r.right, (long)r.bottom, wp.showCmd == SW_SHOWMAXIMIZED || IsZoomed(w) ? 1 : 0);
    fclose(f);
}

static void CEF_CALLBACK on_after_created(cef_life_span_handler_t* self, cef_browser_t* browser) {
    (void)self;
    g_browser = browser; // keeps CEF's reference; released in on_before_close
    HWND w = top_window(browser);
    if (!w) return;
    // the app's icon (resource 1, src/app.rc) in the title bar and taskbar
    HINSTANCE inst = GetModuleHandleW(NULL);
    HICON big = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
    HICON small = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    if (big) SendMessageW(w, WM_SETICON, ICON_BIG, (LPARAM)big);
    if (small) SendMessageW(w, WM_SETICON, ICON_SMALL, (LPARAM)small);
    // last size and position
    RECT rc;
    int maxed = 0;
    if (load_place(&rc, &maxed)) {
        WINDOWPLACEMENT wp;
        memset(&wp, 0, sizeof wp);
        wp.length = sizeof wp;
        wp.showCmd = maxed ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
        wp.rcNormalPosition = rc;
        SetWindowPlacement(w, &wp);
    }
}

// Closing: remember the window's size first.
static int CEF_CALLBACK do_close(cef_life_span_handler_t* self, cef_browser_t* browser) {
    (void)self;
    HWND w = top_window(browser);
    if (w) save_place(w);
    RELEASE(browser);
    return 0; // let CEF close the window as usual
}

// Ctrl + mouse wheel (from app-inject.js through /api/zoom): one zoom step, remembered.
void zcef_zoom_step(int dir) {
    if (!g_browser) return;
    int i = step_index(g_zoom);
    int n = (int)(sizeof k_steps / sizeof k_steps[0]);
    if (dir > 0 && i + 1 < n) i++;
    else if (dir < 0 && i > 0) i--;
    else return;
    g_zoom = level_for(k_steps[i]);
    apply_zoom(g_browser);
    save_zoom();
}

static void init_handlers(void) {
    init_base(&g_app.base, sizeof g_app);
    g_app.on_before_command_line_processing = on_before_command_line_processing;
    g_app.on_register_custom_schemes = on_register_custom_schemes;
    init_base(&g_factory.base, sizeof g_factory);
    g_factory.create = scheme_create;

    init_base(&g_client.base, sizeof g_client);
    g_client.get_life_span_handler = get_life;
    g_client.get_download_handler = get_dl;
    g_client.get_keyboard_handler = get_keys;
    g_client.get_load_handler = get_load;
    g_client.get_display_handler = get_display;
    g_client.get_request_handler = get_req_handler;
    init_base(&g_req_handler.base, sizeof g_req_handler);
    g_req_handler.on_before_browse = on_before_browse;

    init_base(&g_life.base, sizeof g_life);
    g_life.on_before_close = on_before_close;
    g_life.on_before_popup = on_before_popup;
    g_life.on_after_created = on_after_created;
    g_life.do_close = do_close;

    init_base(&g_dl.base, sizeof g_dl);
    g_dl.can_download = can_download;
    g_dl.on_before_download = on_before_download;
    g_dl.on_download_updated = on_download_updated;

    init_base(&g_keys.base, sizeof g_keys);
    g_keys.on_pre_key_event = on_pre_key_event;

    init_base(&g_load.base, sizeof g_load);
    g_load.on_load_end = on_load_end;

    init_base(&g_display.base, sizeof g_display);
    g_display.on_title_change = on_title_change;
}

// ---------------------------------------------------------------- Windows file picker (api.zig)
#include <commdlg.h>
// Native "Open file" dialog. Writes a UTF-8 path into out; returns 1 if a file was picked.
int plat_open_file(const wchar_t* filter, char* out, int out_len) {
    wchar_t buf[1024] = L"";
    OPENFILENAMEW ofn;
    memset(&ofn, 0, sizeof ofn);
    ofn.lStructSize = sizeof ofn;
    ofn.hwndOwner = GetActiveWindow();
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = buf;
    ofn.nMaxFile = 1024;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) return 0;
    return WideCharToMultiByte(CP_UTF8, 0, buf, -1, out, out_len, NULL, NULL) > 0 ? 1 : 0;
}

// ---------------------------------------------------------------- entry points (called from main.zig)

static int check_api(void) {
    const char* hash = cef_api_hash(CEF_API_VERSION, 0);
    if (!hash || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        MessageBoxW(NULL, L"The CEF files next to the app don't match the version the app was built for.\nRun 'zig build' again to fetch the right ones.",
                    L"ZZZ .zon Tool", MB_OK | MB_ICONERROR);
        return 0;
    }
    return 1;
}

// Chrome runs helper processes (renderer, GPU, ...) as copies of this .exe. This returns
// their exit code when this process is one of them, or -1 for the main app.
int zcef_subprocess(void) {
    if (!check_api()) return 1;
    init_handlers();
    cef_main_args_t args = { GetModuleHandleW(NULL) };
    return cef_execute_process(&args, &g_app, NULL);
}

// Runs the app window until it's closed. `index_url` is a file:/// URL to the site,
// `data_dir` an absolute folder for the site's saved data (its localStorage).
int zcef_run(const char* index_url, const char* data_dir) {
    snprintf(g_url, sizeof g_url, "%s", index_url);
    snprintf(g_zoom_file, sizeof g_zoom_file, "%s\\zoom.txt", data_dir);
    snprintf(g_place_file, sizeof g_place_file, "%s\\window.txt", data_dir);
    load_zoom();

    cef_main_args_t args = { GetModuleHandleW(NULL) };
    cef_settings_t settings;
    memset(&settings, 0, sizeof settings);
    settings.size = sizeof settings;
    settings.no_sandbox = 1;
    settings.persist_session_cookies = 1;
    settings.log_severity = LOGSEVERITY_DISABLE;
    settings.background_color = 0xff12151b; // the site's --bg, so there's no white flash
    set_str(&settings.root_cache_path, data_dir);
    set_str(&settings.cache_path, data_dir);
    if (!cef_initialize(&args, &settings, &g_app, NULL)) {
        MessageBoxW(NULL, L"Chrome's engine (CEF) couldn't start.", L"ZZZ .zon Tool", MB_OK | MB_ICONERROR);
        return 1;
    }

    {
        cef_string_t sch = {0}, dom = {0};
        set_str(&sch, "zzz");
        set_str(&dom, "app");
        cef_register_scheme_handler_factory(&sch, &dom, &g_factory);
        cef_string_clear(&sch);
        cef_string_clear(&dom);
    }

    cef_window_info_t wi;
    memset(&wi, 0, sizeof wi);
    wi.size = sizeof wi;
    wi.style = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_VISIBLE;
    UINT dpi = GetDpiForSystem();
    wi.bounds.x = CW_USEDEFAULT;
    wi.bounds.y = CW_USEDEFAULT;
    wi.bounds.width = MulDiv(1180, dpi, 96);
    wi.bounds.height = MulDiv(940, dpi, 96);
    {
        RECT rc;
        int maxed = 0;
        if (load_place(&rc, &maxed)) {
            wi.bounds.x = rc.left;
            wi.bounds.y = rc.top;
            wi.bounds.width = rc.right - rc.left;
            wi.bounds.height = rc.bottom - rc.top;
        }
    }
    wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY; // a plain window: no Chrome toolbar
    set_str(&wi.window_name, "ZZZ .zon Tool");

    cef_browser_settings_t bs;
    memset(&bs, 0, sizeof bs);
    bs.size = sizeof bs;
    bs.background_color = 0xff12151b;

    cef_string_t url = {0};
    set_str(&url, g_url);
    cef_browser_host_create_browser(&wi, &g_client, &url, &bs, NULL, NULL);
    cef_string_clear(&url);

    cef_run_message_loop();
    cef_shutdown();
    return 0;
}

// ---------------------------------------------------------------- the Remielle server
// Started from App tools > Game save, in its own command window (as if you ran it yourself),
// with the game folder as its working folder. Stop sends it Ctrl+C - the same as pressing it
// in that window - so it shuts down cleanly; only if it's still running 10 s later is it ended.

static HANDLE g_srv = NULL;
static DWORD g_srv_pid = 0;

static int utf8_to_w(const char* s, wchar_t* out, int n) {
    int k = MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n);
    if (k <= 0) out[0] = 0;
    return k;
}

// Starts exe in its own window, from dir. Programs that need admin rights (Windows error 740
// with CreateProcess) are started like a double-click instead, which shows Windows' own
// "Do you want to allow this app...?" prompt. *proc gets the process (NULL if not wanted).
static int start_program(const char* exe, const char* dir, HANDLE* proc, DWORD* pid) {
    wchar_t wexe[2048], wdir[2048], cmd[2100];
    if (utf8_to_w(exe, wexe, 2048) <= 0 || utf8_to_w(dir, wdir, 2048) <= 0) return (int)ERROR_INVALID_PARAMETER;
    _snwprintf(cmd, 2099, L"\"%s\"", wexe);
    cmd[2099] = 0;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    memset(&pi, 0, sizeof pi);
    si.cb = sizeof si;
    if (CreateProcessW(wexe, cmd, NULL, NULL, FALSE, CREATE_NEW_CONSOLE, NULL, wdir, &si, &pi)) {
        CloseHandle(pi.hThread);
        if (proc) { *proc = pi.hProcess; *pid = pi.dwProcessId; } else CloseHandle(pi.hProcess);
        return 0;
    }
    DWORD err = GetLastError();
    if (err != ERROR_ELEVATION_REQUIRED) return (int)err;
    SHELLEXECUTEINFOW se;
    memset(&se, 0, sizeof se);
    se.cbSize = sizeof se;
    se.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    se.lpVerb = L"open";
    se.lpFile = wexe;
    se.lpDirectory = wdir;
    se.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&se)) return (int)GetLastError(); // 1223: "No" on the prompt
    if (proc) { *proc = se.hProcess; *pid = se.hProcess ? GetProcessId(se.hProcess) : 0; }
    else if (se.hProcess) CloseHandle(se.hProcess);
    return 0;
}

int plat_server_running(void) {
    if (!g_srv) return 0;
    if (WaitForSingleObject(g_srv, 0) == WAIT_TIMEOUT) return 1;
    CloseHandle(g_srv);
    g_srv = NULL;
    g_srv_pid = 0;
    return 0;
}

int plat_server_start(const char* exe, const char* dir) {
    if (plat_server_running()) return 0;
    HANDLE h = NULL;
    DWORD pid = 0;
    int rc = start_program(exe, dir, &h, &pid);
    if (rc != 0) return rc;
    g_srv = h;
    g_srv_pid = pid;
    return 0;
}

int plat_server_stop(void) {
    if (!plat_server_running()) return 1;
    // Ctrl+C into the server's own window: join its console for a moment (this app has none)
    if (AttachConsole(g_srv_pid)) {
        SetConsoleCtrlHandler(NULL, TRUE); // this app ignores the Ctrl+C itself
        GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
        FreeConsole();
    }
    // (a server running as admin can't be reached from here: then it has to be closed by hand)
    if (WaitForSingleObject(g_srv, 10000) != WAIT_OBJECT_0) {
        TerminateProcess(g_srv, 1);
        WaitForSingleObject(g_srv, 3000);
    }
    return !plat_server_running();
}

// The game's launcher (remielle.exe in the CNBetaWin folder): its own window, its own folder.
int plat_launch(const char* exe, const char* dir) {
    return start_program(exe, dir, NULL, NULL);
}

// Restart game: the game runs as administrator (remielle-bootstrap needs it), and Windows won't
// let this app close an administrator program. So one elevated command does both - one Windows
// prompt: close every program running from the game's folder (never the server), then start
// remielle-bootstrap again. Returns 0, 1223 when No was clicked on the prompt, or a Windows error.
int plat_game_restart(const char* exe, const char* dir) {
    wchar_t wexe[2048], wdir[2048];
    if (utf8_to_w(exe, wexe, 2048) <= 0 || utf8_to_w(dir, wdir, 2048) <= 0) return (int)ERROR_INVALID_PARAMETER;
    size_t dlen = wcslen(wdir);
    while (dlen > 0 && (wdir[dlen - 1] == L'\\' || wdir[dlen - 1] == L'/')) wdir[--dlen] = 0;

    // the programs running from the game folder
    static wchar_t params[8192];
    int n = _snwprintf(params, 8000, L"/c taskkill /F /T");
    int found = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe;
        memset(&pe, 0, sizeof pe);
        pe.dwSize = sizeof pe;
        DWORD me = GetCurrentProcessId();
        for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe)) {
            if (pe.th32ProcessID == me || pe.th32ProcessID == 0 || (g_srv_pid && pe.th32ProcessID == g_srv_pid)) continue;
            HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
            if (!h) continue;
            wchar_t path[2048];
            DWORD plen = 2048;
            if (QueryFullProcessImageNameW(h, 0, path, &plen) && plen > dlen && _wcsnicmp(path, wdir, dlen) == 0 && (path[dlen] == L'\\' || path[dlen] == L'/')) {
                if (n < 7900) n += _snwprintf(params + n, 8000 - n, L" /PID %lu", (unsigned long)pe.th32ProcessID);
                found++;
            }
            CloseHandle(h);
        }
        CloseHandle(snap);
    }
    // nothing running: just start it (a normal start, its own prompt as usual)
    if (found == 0) return plat_launch(exe, dir);
    // close them, wait a moment, start remielle-bootstrap from its folder (already elevated: no second prompt)
    _snwprintf(params + n, 8190 - n, L" & timeout /t 2 /nobreak >nul & start \"\" /D \"%s\" \"%s\"", wdir, wexe);
    params[8191] = 0;
    SHELLEXECUTEINFOW se;
    memset(&se, 0, sizeof se);
    se.cbSize = sizeof se;
    se.fMask = SEE_MASK_NOASYNC;
    se.lpVerb = L"runas";
    se.lpFile = L"cmd.exe";
    se.lpParameters = params;
    se.lpDirectory = wdir;
    se.nShow = SW_HIDE;
    if (!ShellExecuteExW(&se)) return (int)GetLastError();
    return 0;
}
