#include <dirent.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lua_priv.h"

#define HEAP_MAX        (48 * 1024)
#define STEPS_MAX       200000
#define HOOK_EVERY      1000
#define OBJ_MAX         64
#define TEXT_MAX        200
#define TEXT_TOTAL      (6 * 1024)
#define TICK_MS         50
#define MESH_PER_S      4
#define MESH_MAX        200
#define LED_COUNT       8
#define READ_MAX        (16 * 1024)
#define READ_CHUNK      256
#define OPEN_STEPS      500
#define BYTES_PER_STEP  4
#define BADGES_MAX      12
#define EVENTS_MAX      4096
#define LOG_MAX         256
#define CHUNKS_MAX      80
#define SCREEN_W        320
#define SCREEN_H        218
#define STEP_MS         5

enum { LABEL, RECT, BAR, LIST, KINDS };
static const char *const s_meta[KINDS] = {"ui.label", "ui.rect", "ui.bar", "ui.list"};
static const char *const s_keys[] = {"up", "down", "left", "right", "select", "back"};

typedef struct {
    bool used, hidden;
    int kind, order, x, y, w, h, value, items_ref, select_ref, count, sel;
    uint32_t gen, color;
    char text[TEXT_MAX + 1];
    size_t text_len;
} obj_t;

typedef struct {
    uint32_t slot, gen;
} handle_t;

typedef struct {
    char path[96];
    char *data;
    size_t size;
} chunk_t;

typedef struct {
    int64_t at;
    int to, from, key;
    char fromid[8];
    bool repeat;
    char *json;
} event_t;

typedef struct badge {
    int index;
    char id[8], owner[40], dir[512], err[512], title[64];
    bool has_owner, store, failed, exited, killed, mem_hit;
    lua_State *L;
    size_t mem, peak;
    unsigned steps, steps_peak;
    int64_t t0, next_tick;
    obj_t objs[OBJ_MAX];
    int order;
    size_t text_total;
    char hint[TEXT_MAX + 1];
    char toasts[16][TEXT_MAX + 1];
    int toast_n;
    uint32_t led[LED_COUNT];
    int store_ref;
    char *saved, *pending;
    int64_t mesh_sent[MESH_PER_S];
    int sent, dropped, too_fast, too_big;
    chunk_t chunks[CHUNKS_MAX];
    int nchunks;
    char *logs[LOG_MAX];
    int log_n;
} badge_t;

static badge_t *s_b[BADGES_MAX];
static int s_n;
static int64_t s_now;
static int64_t s_epoch = 1793000000;
static bool s_has_time = true;
static bool s_link[BADGES_MAX][BADGES_MAX];
static int s_rssi[BADGES_MAX][BADGES_MAX];
static double s_loss;
static int s_latency = 15, s_jitter = 10;
static double s_dup;
static event_t s_ev[EVENTS_MAX];
static int s_nev;
static uint64_t s_rng = 0x9E3779B97F4A7C15ull;
static bool s_echo;

static double rnd(void)
{
    s_rng ^= s_rng << 13;
    s_rng ^= s_rng >> 7;
    s_rng ^= s_rng << 17;
    return (double)(s_rng >> 11) / 9007199254740992.0;
}

static badge_t *get(lua_State *L)
{
    return *(badge_t **)lua_getextraspace(L);
}

static void blog(badge_t *b, const char *fmt, ...)
{
    char line[600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (s_echo) {
        printf("  [%s %6lld] %s\n", b->id, (long long)s_now, line);
    }
    free(b->logs[b->log_n % LOG_MAX]);
    b->logs[b->log_n % LOG_MAX] = strdup(line);
    b->log_n++;
}

static void *alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
    badge_t *b = ud;
    size_t old = ptr ? osize : 0;
    if (nsize == 0) {
        free(ptr);
        b->mem -= old;
        return NULL;
    }
    if (nsize > old && b->mem - old + nsize > HEAP_MAX) {
        if (s_echo) {
            printf("  [%s %6lld] alloc refused: heap %zu, asked %zu\n", b->id, (long long)s_now, b->mem, nsize);
        }
        b->mem_hit = true;
        return NULL;
    }
    void *p = realloc(ptr, nsize);
    if (p) {
        b->mem = b->mem - old + nsize;
        if (b->mem > b->peak) {
            b->peak = b->mem;
        }
    }
    return p;
}

int lh_cstack_check(void)
{
    return 0;
}

static void over_budget(lua_State *L)
{
    get(L)->killed = true;
    luaL_error(L, "Script took too long");
}

static void step_hook(lua_State *L, lua_Debug *ar)
{
    (void)ar;
    badge_t *b = get(L);
    b->steps += HOOK_EVERY;
    if (b->steps > STEPS_MAX) {
        over_budget(L);
    }
}

void lh_charge_steps(lua_State *L, unsigned int n)
{
    badge_t *b = get(L);
    if (!b) {
        return;
    }
    b->steps += n;
    if (b->steps > STEPS_MAX) {
        over_budget(L);
    }
}

void lh_thread_new(lua_State *L1)
{
    lua_sethook(L1, step_hook, LUA_MASKCOUNT, HOOK_EVERY);
}

static void close_app(badge_t *b)
{
    if (b->pending) {
        free(b->saved);
        b->saved = b->pending;
        b->pending = NULL;
    }
    if (b->L) {
        lua_close(b->L);
        b->L = NULL;
    }
    memset(b->objs, 0, sizeof(b->objs));
    b->text_total = 0;
    b->hint[0] = 0;
    memset(b->led, 0, sizeof(b->led));
    for (int i = 0; i < s_nev; i++) {
        if (s_ev[i].to == b->index && s_ev[i].json) {
            free(s_ev[i].json);
            s_ev[i].json = NULL;
            s_ev[i].to = -1;
        }
    }
}

static void fail(badge_t *b, int rc)
{
    lua_State *L = b->L;
    const char *msg = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "(error is not a string)";
    if (rc != LUA_ERRMEM && b->mem_hit && !strcmp(msg, "not enough memory")) {
        rc = LUA_ERRMEM;
    }
    if (rc == LUA_ERRMEM) {
        snprintf(b->title, sizeof(b->title), "Out of memory");
        snprintf(b->err, sizeof(b->err), "The app needs more than %d KB.", HEAP_MAX / 1024);
    } else {
        snprintf(b->title, sizeof(b->title), b->killed ? "Script took too long" : "Script error");
        snprintf(b->err, sizeof(b->err), "%s", msg);
    }
    blog(b, "%s: %s", b->title, b->err);
    b->failed = true;
    close_app(b);
}

static bool callback(badge_t *b, lua_CFunction fn, void *arg)
{
    lua_State *L = b->L;
    if (!L || b->failed) {
        return false;
    }
    b->steps = 0;
    b->killed = false;
    lua_pushcfunction(L, fn);
    lua_pushlightuserdata(L, arg);
    int rc = lua_pcall(L, 1, 0, 0);
    if (b->steps > b->steps_peak) {
        b->steps_peak = b->steps;
    }
    if (rc != LUA_OK) {
        fail(b, rc);
        return false;
    }
    if (b->killed) {
        lua_pushliteral(L, "Script took too long");
        fail(b, LUA_ERRRUN);
        return false;
    }
    return true;
}

static uint32_t color_of(lua_State *L, int idx)
{
    static const struct {
        const char *name;
        uint32_t col;
    } names[] = {
        {"text", 0xF2F2F2}, {"dim", 0x8A8A99}, {"bg", 0x0B0B12}, {"panel", 0x16161F}, {"border", 0x2A2A38},
        {"purple", 0x9945FF}, {"green", 0x14F195}, {"pink", 0xFF5FA2}, {"lpurple", 0xB98CFF},
        {"blue", 0x3B82F6}, {"aqua", 0x00D1FF}, {"lime", 0xA3E635}, {"yellow", 0xFACC15}, {"orange", 0xFB923C},
    };
    int is_int;
    lua_Integer hex = lua_tointegerx(L, idx, &is_int);
    if (is_int) {
        return (uint32_t)hex & 0xFFFFFF;
    }
    const char *name = lua_type(L, idx) == LUA_TSTRING ? lua_tostring(L, idx) : "";
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (!strcmp(name, names[i].name)) {
            return names[i].col;
        }
    }
    luaL_error(L, "colour must be a theme name or 0xRRGGBB, not '%s'", name[0] ? name : luaL_typename(L, idx));
    return 0;
}

static int opt_int(lua_State *L, int t, const char *key, int def)
{
    if (lua_type(L, t) != LUA_TTABLE) {
        return def;
    }
    lua_getfield(L, t, key);
    int is_int;
    lua_Integer v = lua_tointegerx(L, -1, &is_int);
    if (!is_int && !lua_isnil(L, -1)) {
        luaL_error(L, "option '%s' must be a whole number", key);
    }
    lua_pop(L, 1);
    return is_int ? (int)v : def;
}

static bool opt_field(lua_State *L, int t, const char *key)
{
    if (lua_type(L, t) != LUA_TTABLE) {
        return false;
    }
    lua_getfield(L, t, key);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    return true;
}

static void clip(char out[TEXT_MAX + 1], const char *in)
{
    size_t n = strlen(in);
    if (n <= TEXT_MAX) {
        memcpy(out, in, n + 1);
        return;
    }
    size_t cut = TEXT_MAX - 3;
    while (cut > 0 && ((unsigned char)in[cut] & 0xC0) == 0x80) {
        cut--;
    }
    memcpy(out, in, cut);
    memcpy(out + cut, "...", 4);
}

static void check_text(lua_State *L, badge_t *b, size_t old, size_t len)
{
    if (b->text_total - old + len > TEXT_TOTAL) {
        luaL_error(L, "too much text on screen (%d KB per app)", TEXT_TOTAL / 1024);
    }
}

static obj_t *new_obj(lua_State *L, int kind, int x, int y, int w, int h)
{
    badge_t *b = get(L);
    for (int i = 0; i < OBJ_MAX; i++) {
        obj_t *o = &b->objs[i];
        if (o->used) {
            continue;
        }
        uint32_t gen = o->gen;
        memset(o, 0, sizeof(*o));
        o->used = true;
        o->gen = gen;
        o->kind = kind;
        o->order = ++b->order;
        o->x = x;
        o->y = y;
        o->w = w;
        o->h = h;
        o->items_ref = o->select_ref = LUA_NOREF;
        handle_t *hd = lua_newuserdatauv(L, sizeof(*hd), 0);
        hd->slot = (uint32_t)i;
        hd->gen = o->gen;
        luaL_setmetatable(L, s_meta[kind]);
        return o;
    }
    luaL_error(L, "too many UI objects (%d)", OBJ_MAX);
    return NULL;
}

static void free_obj(lua_State *L, badge_t *b, obj_t *o)
{
    if (L) {
        luaL_unref(L, LUA_REGISTRYINDEX, o->items_ref);
        luaL_unref(L, LUA_REGISTRYINDEX, o->select_ref);
    }
    b->text_total -= o->text_len;
    uint32_t gen = o->gen + 1;
    memset(o, 0, sizeof(*o));
    o->gen = gen;
}

static obj_t *check(lua_State *L)
{
    handle_t *h = NULL;
    for (int k = 0; k < KINDS && !h; k++) {
        h = luaL_testudata(L, 1, s_meta[k]);
    }
    if (!h) {
        luaL_typeerror(L, 1, "UI object");
    }
    obj_t *o = &get(L)->objs[h->slot];
    if (!o->used || o->gen != h->gen) {
        luaL_error(L, "this object was removed");
    }
    return o;
}

static int m_pos(lua_State *L)
{
    obj_t *o = check(L);
    o->x = (int)luaL_checkinteger(L, 2);
    o->y = (int)luaL_checkinteger(L, 3);
    return 0;
}

static int m_size(lua_State *L)
{
    obj_t *o = check(L);
    o->w = (int)luaL_checkinteger(L, 2);
    o->h = (int)luaL_checkinteger(L, 3);
    return 0;
}

static int m_show(lua_State *L)
{
    obj_t *o = check(L);
    o->hidden = !(lua_isnone(L, 2) || lua_toboolean(L, 2));
    return 0;
}

static int m_remove(lua_State *L)
{
    handle_t *h = NULL;
    for (int k = 0; k < KINDS && !h; k++) {
        h = luaL_testudata(L, 1, s_meta[k]);
    }
    badge_t *b = get(L);
    if (h && b->objs[h->slot].used && b->objs[h->slot].gen == h->gen) {
        free_obj(L, b, &b->objs[h->slot]);
    }
    return 0;
}

static int m_text(lua_State *L)
{
    obj_t *o = check(L);
    char t[TEXT_MAX + 1];
    clip(t, luaL_checkstring(L, 2));
    badge_t *b = get(L);
    size_t len = strlen(t);
    check_text(L, b, o->text_len, len);
    memcpy(o->text, t, len + 1);
    b->text_total = b->text_total - o->text_len + len;
    o->text_len = len;
    return 0;
}

static int m_color(lua_State *L)
{
    obj_t *o = check(L);
    o->color = color_of(L, 2);
    return 0;
}

static int m_set(lua_State *L)
{
    obj_t *o = check(L);
    int v = (int)luaL_checkinteger(L, 2);
    o->value = v < 0 ? 0 : v > 100 ? 100 : v;
    return 0;
}

static obj_t *check_list(lua_State *L)
{
    obj_t *o = check(L);
    if (o->kind != LIST) {
        luaL_typeerror(L, 1, "list");
    }
    return o;
}

static void list_count(obj_t *o, int count)
{
    o->count = count;
    if (o->sel >= count) {
        o->sel = count ? count - 1 : 0;
    }
    if (o->sel < 0) {
        o->sel = 0;
    }
}

static int m_items(lua_State *L)
{
    obj_t *o = check_list(L);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_pushvalue(L, 2);
    lua_rawseti(L, LUA_REGISTRYINDEX, o->items_ref);
    list_count(o, (int)lua_rawlen(L, 2));
    return 0;
}

static int m_selected(lua_State *L)
{
    obj_t *o = check_list(L);
    if (o->count) {
        lua_pushinteger(L, o->sel + 1);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int m_select(lua_State *L)
{
    obj_t *o = check_list(L);
    o->sel = (int)luaL_checkinteger(L, 2) - 1;
    list_count(o, o->count);
    return 0;
}

static int l_label(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    char text[TEXT_MAX + 1];
    clip(text, luaL_checkstring(L, 3));
    int size = opt_int(L, 4, "size", 14);
    int w = opt_int(L, 4, "w", 0);
    if (size != 12 && size != 14 && size != 20 && size != 32) {
        luaL_error(L, "size must be 12, 14, 20 or 32");
    }
    uint32_t color = 0xF2F2F2;
    if (opt_field(L, 4, "color")) {
        color = color_of(L, -1);
        lua_pop(L, 1);
    }
    badge_t *b = get(L);
    size_t len = strlen(text);
    check_text(L, b, 0, len);
    obj_t *o = new_obj(L, LABEL, x, y, w, size);
    o->color = color;
    memcpy(o->text, text, len + 1);
    o->text_len = len;
    b->text_total += len;
    return 1;
}

static int l_rect(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3), h = (int)luaL_checkinteger(L, 4);
    uint32_t color = 0x16161F;
    if (opt_field(L, 5, "color")) {
        color = color_of(L, -1);
        lua_pop(L, 1);
    }
    opt_int(L, 5, "radius", 0);
    if (opt_field(L, 5, "border")) {
        color_of(L, -1);
        lua_pop(L, 1);
    }
    new_obj(L, RECT, x, y, w, h)->color = color;
    return 1;
}

static int l_bar(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3), h = (int)luaL_checkinteger(L, 4);
    int v = (int)luaL_optinteger(L, 5, 0);
    new_obj(L, BAR, x, y, w, h)->value = v < 0 ? 0 : v > 100 ? 100 : v;
    return 1;
}

static int l_list(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3), h = (int)luaL_checkinteger(L, 4);
    luaL_checktype(L, 5, LUA_TTABLE);
    bool has_select = opt_field(L, 6, "on_select");
    if (has_select && !lua_isfunction(L, -1)) {
        luaL_error(L, "on_select must be a function");
    }
    obj_t *o = new_obj(L, LIST, x, y, w, h);
    if (has_select) {
        lua_pushvalue(L, -2);
        o->select_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    lua_pushvalue(L, 5);
    o->items_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    list_count(o, (int)lua_rawlen(L, 5));
    return 1;
}

static int l_bg(lua_State *L)
{
    color_of(L, 1);
    return 0;
}

static int l_hint(lua_State *L)
{
    badge_t *b = get(L);
    char t[TEXT_MAX + 1];
    clip(t, luaL_optstring(L, 1, ""));
    if (strcmp(t, b->hint)) {
        blog(b, "hint: %s (heap %zu)", t, b->mem);
    }
    memcpy(b->hint, t, sizeof(t));
    return 0;
}

static int l_toast(lua_State *L)
{
    badge_t *b = get(L);
    clip(b->toasts[b->toast_n % 16], luaL_checkstring(L, 1));
    blog(b, "toast: %s", b->toasts[b->toast_n % 16]);
    b->toast_n++;
    return 0;
}

static int l_clear(lua_State *L)
{
    badge_t *b = get(L);
    blog(b, "ui.clear (heap %zu)", b->mem);
    for (int i = 0; i < OBJ_MAX; i++) {
        if (b->objs[i].used) {
            free_obj(L, b, &b->objs[i]);
        }
    }
    b->hint[0] = 0;
    return 0;
}

static void open_ui(lua_State *L)
{
    static const luaL_Reg label[] = {{"pos", m_pos}, {"show", m_show}, {"remove", m_remove}, {"text", m_text},
                                     {"color", m_color}, {NULL, NULL}};
    static const luaL_Reg rect[] = {{"pos", m_pos}, {"show", m_show}, {"remove", m_remove}, {"size", m_size},
                                    {"color", m_color}, {NULL, NULL}};
    static const luaL_Reg bar[] = {{"pos", m_pos}, {"show", m_show}, {"remove", m_remove}, {"set", m_set},
                                   {"size", m_size}, {NULL, NULL}};
    static const luaL_Reg list[] = {{"pos", m_pos}, {"show", m_show}, {"remove", m_remove}, {"items", m_items},
                                    {"selected", m_selected}, {"select", m_select}, {NULL, NULL}};
    const luaL_Reg *methods[KINDS] = {label, rect, bar, list};
    for (int k = 0; k < KINDS; k++) {
        luaL_newmetatable(L, s_meta[k]);
        luaL_newlib(L, methods[k]);
        lua_setfield(L, -2, "__index");
        lua_pop(L, 1);
    }
    static const luaL_Reg ui[] = {{"label", l_label}, {"rect", l_rect}, {"bar", l_bar}, {"list", l_list},
                                  {"bg", l_bg}, {"hint", l_hint}, {"toast", l_toast}, {"clear", l_clear},
                                  {NULL, NULL}};
    luaL_newlib(L, ui);
    lua_pushinteger(L, SCREEN_W);
    lua_setfield(L, -2, "W");
    lua_pushinteger(L, SCREEN_H);
    lua_setfield(L, -2, "H");
    lua_setglobal(L, "ui");
}

static int channel(lua_State *L, int idx)
{
    lua_Integer v = luaL_checkinteger(L, idx);
    return v < 0 ? 0 : v > 255 ? 255 : (int)v;
}

static int l_led_set(lua_State *L)
{
    lua_Integer i = luaL_checkinteger(L, 1);
    luaL_argcheck(L, i >= 1 && i <= LED_COUNT, 1, "LEDs are 1..8");
    get(L)->led[i - 1] = (uint32_t)(channel(L, 2) << 16 | channel(L, 3) << 8 | channel(L, 4));
    return 0;
}

static int l_led_fill(lua_State *L)
{
    badge_t *b = get(L);
    uint32_t c = (uint32_t)(channel(L, 1) << 16 | channel(L, 2) << 8 | channel(L, 3));
    for (int i = 0; i < LED_COUNT; i++) {
        b->led[i] = c;
    }
    return 0;
}

static int l_led_off(lua_State *L)
{
    memset(get(L)->led, 0, sizeof(get(L)->led));
    return 0;
}

static int l_millis(lua_State *L)
{
    lua_pushinteger(L, (lua_Integer)(s_now - get(L)->t0));
    return 1;
}

static int l_time(lua_State *L)
{
    if (s_has_time) {
        lua_pushinteger(L, (lua_Integer)(s_epoch + s_now / 1000));
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int l_badge_id(lua_State *L)
{
    lua_pushstring(L, get(L)->id);
    return 1;
}

static int l_badge_owner(lua_State *L)
{
    badge_t *b = get(L);
    if (b->has_owner) {
        lua_pushstring(L, b->owner);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int l_get(lua_State *L)
{
    badge_t *b = get(L);
    luaL_checkstring(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, b->store_ref);
    lua_pushvalue(L, 1);
    lua_rawget(L, -2);
    return 1;
}

static int l_set(lua_State *L)
{
    badge_t *b = get(L);
    luaL_checkstring(L, 1);
    int type = lua_type(L, 2);
    luaL_argcheck(L, type == LUA_TNIL || type == LUA_TNONE || type == LUA_TNUMBER || type == LUA_TSTRING
                  || type == LUA_TBOOLEAN || type == LUA_TTABLE, 2, "storage takes numbers, strings, booleans and tables");
    lua_settop(L, 2);
    lua_rawgeti(L, LUA_REGISTRYINDEX, b->store_ref);
    int t = lua_gettop(L);
    lua_pushvalue(L, 1);
    lua_rawget(L, t);
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_rawset(L, t);
    lh_jbuf_t jb = {.max = LH_STORAGE_MAX};
    if (!lh_json_encode(L, t, &jb)) {
        free(jb.p);
        lua_pushvalue(L, 1);
        lua_pushvalue(L, -2);
        lua_rawset(L, t);
        return luaL_error(L, "storage: %s", !strcmp(jb.err, "too big") ? "full (16 KB per app)" : jb.err);
    }
    free(b->pending);
    b->pending = jb.p;
    return 0;
}

static int l_remove(lua_State *L)
{
    lua_settop(L, 1);
    lua_pushnil(L);
    return l_set(L);
}

static void open_sys(lua_State *L)
{
    static const luaL_Reg led[] = {{"set", l_led_set}, {"fill", l_led_fill}, {"off", l_led_off}, {NULL, NULL}};
    static const luaL_Reg sys[] = {{"millis", l_millis}, {"time", l_time}, {NULL, NULL}};
    static const luaL_Reg badge[] = {{"id", l_badge_id}, {"owner", l_badge_owner}, {NULL, NULL}};
    static const luaL_Reg storage[] = {{"get", l_get}, {"set", l_set}, {"remove", l_remove}, {NULL, NULL}};
    luaL_newlib(L, led);
    lua_setglobal(L, "led");
    luaL_newlib(L, sys);
    lua_setglobal(L, "sys");
    luaL_newlib(L, badge);
    lua_setglobal(L, "badge");
    luaL_newlib(L, storage);
    lua_setglobal(L, "storage");
}

static void full_path(lua_State *L, badge_t *b, const char *rel, char *out, size_t n)
{
    if (!rel[0] || rel[0] == '/' || strstr(rel, "..")) {
        luaL_error(L, "bad path '%s'", rel);
    }
    snprintf(out, n, "%s/%s", b->dir, rel);
}

static int l_read(lua_State *L)
{
    badge_t *b = get(L);
    const char *rel = luaL_checkstring(L, 1);
    lua_Integer off = luaL_optinteger(L, 2, 0);
    luaL_argcheck(L, off >= 0, 2, "offsets count from 0");
    bool whole = lua_isnoneornil(L, 3);
    lua_Integer len = whole ? 0 : luaL_checkinteger(L, 3);
    luaL_argcheck(L, len >= 0 && len <= READ_MAX, 3, "at most 16 KB per read");
    char path[700];
    full_path(L, b, rel, path, sizeof(path));
    lh_charge_steps(L, OPEN_STEPS);
    FILE *f = fopen(path, "rb");
    if (!f) {
        lua_pushnil(L);
        lua_pushfstring(L, "%s: not found", rel);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    long left = off < size ? size - (long)off : 0;
    if (whole && left > READ_MAX) {
        fclose(f);
        return luaL_error(L, "fs.read: %s is %d bytes; read it in pieces of at most 16 KB", rel, (int)size);
    }
    long n = whole || len > left ? left : (long)len;
    lh_charge_steps(L, (unsigned)(n / BYTES_PER_STEP));
    char *buf = malloc((size_t)n + 1);
    fseek(f, off, SEEK_SET);
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    lua_pushlstring(L, buf, got);
    free(buf);
    return 1;
}

typedef struct {
    FILE *f;
    long left;
    char buf[READ_CHUNK];
} reader_t;

static const char *read_piece(lua_State *L, void *ud, size_t *size)
{
    (void)L;
    reader_t *r = ud;
    size_t want = r->left < (long)sizeof(r->buf) ? (size_t)r->left : sizeof(r->buf);
    *size = want ? fread(r->buf, 1, want, r->f) : 0;
    r->left -= (long)*size;
    return *size ? r->buf : NULL;
}

typedef struct {
    const char *p;
    size_t n;
} whole_t;

static const char *read_whole(lua_State *L, void *ud, size_t *size)
{
    (void)L;
    whole_t *w = ud;
    *size = w->n;
    w->n = 0;
    return *size ? w->p : NULL;
}

static int compile(lua_State *L, badge_t *b, const char *rel)
{
    char name[128];
    snprintf(name, sizeof(name), "=%s", rel);
    lh_charge_steps(L, OPEN_STEPS);
    if (b->store) {
        for (int i = 0; i < b->nchunks; i++) {
            if (!strcmp(b->chunks[i].path, rel)) {
                whole_t w = {b->chunks[i].data, b->chunks[i].size};
                return lua_load(L, read_whole, &w, name, "B");
            }
        }
    }
    char path[700];
    full_path(L, b, rel, path, sizeof(path));
    struct stat st;
    if (stat(path, &st) != 0) {
        lua_pushfstring(L, "%s: not found", rel);
        return -1;
    }
    lh_charge_steps(L, (unsigned)(st.st_size / BYTES_PER_STEP));
    reader_t r = {.f = fopen(path, "rb"), .left = st.st_size};
    int rc = lua_load(L, read_piece, &r, name, "t");
    fclose(r.f);
    return rc;
}

static int l_load(lua_State *L)
{
    badge_t *b = get(L);
    int rc = compile(L, b, luaL_checkstring(L, 1));
    if (rc == LUA_OK) {
        return 1;
    }
    lua_pushnil(L);
    lua_insert(L, -2);
    return 2;
}

static int l_exists(lua_State *L)
{
    char path[700];
    struct stat st;
    full_path(L, get(L), luaL_checkstring(L, 1), path, sizeof(path));
    lua_pushboolean(L, stat(path, &st) == 0);
    return 1;
}

static int l_require(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    char rel[128];
    snprintf(rel, sizeof(rel), "%s", name);
    for (char *p = rel; *p; p++) {
        if (*p == '.') {
            *p = '/';
        }
    }
    strncat(rel, ".lua", sizeof(rel) - strlen(rel) - 1);
    lua_settop(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, "sim.loaded");
    lua_getfield(L, 2, name);
    if (!lua_isnil(L, 3)) {
        return 1;
    }
    lua_pop(L, 1);
    if (compile(L, get(L), rel) != LUA_OK) {
        return lua_error(L);
    }
    lua_call(L, 0, 1);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_pushboolean(L, 1);
    }
    lua_pushvalue(L, -1);
    lua_setfield(L, 2, name);
    return 1;
}

static void open_fs(lua_State *L)
{
    static const luaL_Reg fs[] = {{"read", l_read}, {"load", l_load}, {"exists", l_exists}, {NULL, NULL}};
    luaL_newlib(L, fs);
    lua_setglobal(L, "fs");
    lua_newtable(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "sim.loaded");
    lua_register(L, "require", l_require);
}

static badge_t *by_id(const char *id)
{
    for (int i = 0; i < s_n; i++) {
        if (!strcmp(s_b[i]->id, id)) {
            return s_b[i];
        }
    }
    return NULL;
}

static void post(int to, const char *from, const char *json, int64_t at)
{
    if (s_nev >= EVENTS_MAX) {
        return;
    }
    event_t *e = &s_ev[s_nev++];
    memset(e, 0, sizeof(*e));
    e->at = at;
    e->to = to;
    e->key = -1;
    snprintf(e->fromid, sizeof(e->fromid), "%s", from);
    e->json = strdup(json);
}

static int l_mesh_send(lua_State *L)
{
    badge_t *b = get(L);
    const char *to = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    bool bcast = !strcmp(to, "*");
    luaL_argcheck(L, bcast || strlen(to) == 6, 1, "a badge id or \"*\"");
    int oldest = 0;
    for (int i = 1; i < MESH_PER_S; i++) {
        if (b->mesh_sent[i] < b->mesh_sent[oldest]) {
            oldest = i;
        }
    }
    if (b->mesh_sent[oldest] && s_now - b->mesh_sent[oldest] < 1000) {
        b->too_fast++;
        lua_getfield(L, 2, "t");
        lua_getfield(L, 2, "c");
        blog(b, "mesh.send too fast: t=%s c=%s", lua_tostring(L, -2) ? lua_tostring(L, -2) : "?",
             lua_tostring(L, -1) ? lua_tostring(L, -1) : "-");
        lua_pop(L, 2);
        lua_pushnil(L);
        lua_pushliteral(L, "too fast: 4 messages per second");
        return 2;
    }
    lh_jbuf_t d = {.max = MESH_MAX};
    if (!lh_json_encode(L, 2, &d)) {
        free(d.p);
        b->too_big++;
        blog(b, "mesh.send refused: %s", d.err);
        lua_pushnil(L);
        lua_pushstring(L, strcmp(d.err, "too big") ? d.err : "message over 200 bytes");
        return 2;
    }
    badge_t *target = bcast ? NULL : by_id(to);
    if (!bcast && (!target || !s_link[b->index][target->index])) {
        free(d.p);
        lua_pushnil(L);
        lua_pushliteral(L, "not nearby");
        return 2;
    }
    for (int i = 0; i < s_n; i++) {
        badge_t *r = s_b[i];
        if (r == b || (target && r != target) || !s_link[b->index][i]) {
            continue;
        }
        if (s_loss > 0 && rnd() < s_loss) {
            b->dropped++;
            continue;
        }
        post(i, b->id, d.p, s_now + s_latency + (int64_t)(rnd() * s_jitter));
        if (s_dup > 0 && rnd() < s_dup) {
            post(i, b->id, d.p, s_now + s_latency + (int64_t)(rnd() * s_jitter));
        }
    }
    free(d.p);
    b->sent++;
    b->mesh_sent[oldest] = s_now ? s_now : 1;
    lua_pushboolean(L, 1);
    return 1;
}

static int l_mesh_nearby(lua_State *L)
{
    badge_t *b = get(L);
    lua_newtable(L);
    int n = 0;
    for (int i = 0; i < s_n; i++) {
        if (i == b->index || !s_link[b->index][i] || s_b[i]->exited) {
            continue;
        }
        lua_createtable(L, 0, 6);
        lua_pushstring(L, s_b[i]->id);
        lua_setfield(L, -2, "id");
        lua_pushstring(L, s_b[i]->has_owner ? s_b[i]->owner : "");
        lua_setfield(L, -2, "name");
        lua_pushinteger(L, 1);
        lua_setfield(L, -2, "level");
        lua_pushinteger(L, s_rssi[b->index][i]);
        lua_setfield(L, -2, "rssi");
        lua_pushliteral(L, "badge");
        lua_setfield(L, -2, "kind");
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "bridged");
        lua_rawseti(L, -2, ++n);
    }
    return 1;
}

static void open_mesh(lua_State *L)
{
    static const luaL_Reg mesh[] = {{"send", l_mesh_send}, {"nearby", l_mesh_nearby}, {NULL, NULL}};
    luaL_newlib(L, mesh);
    lua_setglobal(L, "mesh");
}

static int l_collectgarbage(lua_State *L)
{
    const char *opt = luaL_optstring(L, 1, "collect");
    luaL_argcheck(L, !strcmp(opt, "count"), 1, "only \"count\" is available");
    lua_pushnumber(L, (lua_Number)lua_gc(L, LUA_GCCOUNT) + (lua_Number)lua_gc(L, LUA_GCCOUNTB) / 1024);
    return 1;
}

static int l_print(lua_State *L)
{
    luaL_Buffer buf;
    int n = lua_gettop(L);
    luaL_buffinit(L, &buf);
    for (int i = 1; i <= n; i++) {
        if (i > 1) {
            luaL_addchar(&buf, '\t');
        }
        luaL_tolstring(L, i, NULL);
        luaL_addvalue(&buf);
    }
    luaL_pushresult(&buf);
    blog(get(L), "%s", lua_tostring(L, -1));
    return 0;
}

static const char *read_main(lua_State *L, void *ud, size_t *size)
{
    (void)L;
    reader_t *r = ud;
    *size = fread(r->buf, 1, sizeof(r->buf), r->f);
    return *size ? r->buf : NULL;
}

static int boot(lua_State *L)
{
    badge_t *b = get(L);
    int rc;
    whole_t w = {NULL, 0};
    if (b->store && b->nchunks && !strcmp(b->chunks[0].path, "main.lua")) {
        w.p = b->chunks[0].data;
        w.n = b->chunks[0].size;
        rc = lua_load(L, read_whole, &w, "=main.lua", "B");
    } else {
        char path[700];
        snprintf(path, sizeof(path), "%s/main.lua", b->dir);
        reader_t r = {.f = fopen(path, "rb")};
        if (!r.f) {
            return luaL_error(L, "main.lua is missing");
        }
        rc = lua_load(L, read_main, &r, "=main.lua", "t");
        fclose(r.f);
    }
    if (rc != LUA_OK) {
        return lua_error(L);
    }
    lua_setfield(L, LUA_REGISTRYINDEX, "sim.main");
    lua_gc(L, LUA_GCCOLLECT);
    static const luaL_Reg libs[] = {
        {LUA_GNAME, luaopen_base}, {LUA_COLIBNAME, luaopen_coroutine}, {LUA_STRLIBNAME, luaopen_string},
        {LUA_TABLIBNAME, luaopen_table}, {LUA_MATHLIBNAME, luaopen_math}, {LUA_UTF8LIBNAME, luaopen_utf8},
    };
    for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]); i++) {
        lua_pushcfunction(L, libs[i].func);
        lua_call(L, 0, 1);
        if (i == 0) {
            lua_pop(L, 1);
        } else {
            lua_setglobal(L, libs[i].name);
        }
    }
    static const char *const drop[] = {"dofile", "loadfile", "load", "warn"};
    for (size_t i = 0; i < sizeof(drop) / sizeof(drop[0]); i++) {
        lua_pushnil(L);
        lua_setglobal(L, drop[i]);
    }
    lua_register(L, "collectgarbage", l_collectgarbage);
    lua_register(L, "print", l_print);
    lua_getglobal(L, LUA_MATHLIBNAME);
    lua_getfield(L, -1, "randomseed");
    lua_pushinteger(L, (lua_Integer)(rnd() * 2147483647.0));
    lua_pushinteger(L, (lua_Integer)(rnd() * 2147483647.0));
    lua_call(L, 2, 0);
    lua_pop(L, 1);
    open_ui(L);
    open_sys(L);
    lh_open_json(L);
    open_mesh(L);
    open_fs(L);
    if (!b->saved || lh_json_decode(L, b->saved, strlen(b->saved)) || !lua_istable(L, -1)) {
        lua_settop(L, 0);
        lua_newtable(L);
    }
    b->store_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_gc(L, LUA_GCCOLLECT);
    lua_gc(L, LUA_GCGEN);
    lua_gc(L, LUA_GCPARAM, LUA_GCPMINORMUL, 10);
    return 0;
}

static int run_main(lua_State *L)
{
    lua_getfield(L, LUA_REGISTRYINDEX, "sim.main");
    lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "sim.main");
    lua_call(L, 0, 0);
    return 0;
}

static int writer(lua_State *L, const void *p, size_t sz, void *ud)
{
    (void)L;
    chunk_t *c = ud;
    if (!p || !sz) {
        return 0;
    }
    char *n = realloc(c->data, c->size + sz);
    if (!n) {
        return 1;
    }
    memcpy(n + c->size, p, sz);
    c->data = n;
    c->size += sz;
    return 0;
}

static void store_compile(badge_t *b, const char *rel)
{
    char path[700];
    snprintf(path, sizeof(path), "%s/%s", b->dir, rel);
    lua_State *C = luaL_newstate();
    if (luaL_loadfilex(C, path, "t") != LUA_OK) {
        fprintf(stderr, "store compile %s: %s\n", rel, lua_tostring(C, -1));
        lua_close(C);
        return;
    }
    chunk_t *c = &b->chunks[b->nchunks];
    memset(c, 0, sizeof(*c));
    snprintf(c->path, sizeof(c->path), "%s", rel);
    lua_dump(C, writer, c, 2);
    lua_close(C);
    b->nchunks++;
}

static void store_walk(badge_t *b, const char *sub)
{
    char path[700];
    snprintf(path, sizeof(path), "%s%s%s", b->dir, sub[0] ? "/" : "", sub);
    DIR *d = opendir(path);
    if (!d) {
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) && b->nchunks < CHUNKS_MAX) {
        if (e->d_name[0] == '.') {
            continue;
        }
        char rel[300];
        snprintf(rel, sizeof(rel), "%s%s%s", sub, sub[0] ? "/" : "", e->d_name);
        size_t n = strlen(rel);
        if (e->d_type == DT_DIR) {
            store_walk(b, rel);
        } else if (n > 4 && !strcmp(rel + n - 4, ".lua") && strcmp(rel, "main.lua")) {
            store_compile(b, rel);
        }
    }
    closedir(d);
}

static void start(badge_t *b)
{
    close_app(b);
    b->failed = b->exited = false;
    b->err[0] = b->title[0] = 0;
    b->mem = b->peak = 0;
    b->mem_hit = false;
    b->steps_peak = 0;
    memset(b->mesh_sent, 0, sizeof(b->mesh_sent));
    b->L = lua_newstate(alloc, b, (unsigned)(rnd() * 4294967295.0));
    *(badge_t **)lua_getextraspace(b->L) = b;
    lua_sethook(b->L, step_hook, LUA_MASKCOUNT, HOOK_EVERY);
    b->t0 = s_now;
    b->next_tick = s_now + TICK_MS;
    blog(b, "launch (%s)", b->store ? "store code" : "compiled on the badge");
    if (callback(b, boot, NULL) && callback(b, run_main, NULL)) {
        blog(b, "booted, heap %zu, peak %zu", b->mem, b->peak);
    }
}

static obj_t *focused_list(badge_t *b)
{
    obj_t *best = NULL;
    for (int i = 0; i < OBJ_MAX; i++) {
        obj_t *o = &b->objs[i];
        if (o->used && o->kind == LIST && !o->hidden && (!best || o->order > best->order)) {
            best = o;
        }
    }
    return best;
}

static int key_cb(lua_State *L)
{
    event_t *ev = lua_touserdata(L, 1);
    badge_t *b = get(L);
    obj_t *o = focused_list(b);
    if (o) {
        if (ev->key == 0 || ev->key == 1) {
            if (o->count) {
                int n = o->sel + (ev->key == 1 ? 1 : -1);
                if (n < 0) {
                    n = ev->repeat ? 0 : o->count - 1;
                } else if (n >= o->count) {
                    n = ev->repeat ? o->count - 1 : 0;
                }
                o->sel = n;
            }
            return 0;
        }
        if (ev->key == 4 && o->select_ref != LUA_NOREF && o->count) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, o->select_ref);
            lua_pushinteger(L, o->sel + 1);
            lua_rawgeti(L, LUA_REGISTRYINDEX, o->items_ref);
            lua_rawgeti(L, -1, o->sel + 1);
            lua_remove(L, -2);
            lua_call(L, 2, 0);
            return 0;
        }
    }
    bool handled = false;
    lua_getglobal(L, "on_key");
    if (lua_isfunction(L, -1)) {
        lua_pushstring(L, s_keys[ev->key]);
        lua_pushboolean(L, ev->repeat);
        lua_call(L, 2, 1);
        handled = lua_toboolean(L, -1);
    }
    if (!handled && ev->key == 5 && !ev->repeat) {
        b->exited = true;
    }
    return 0;
}

static int tick_cb(lua_State *L)
{
    lua_getglobal(L, "on_tick");
    if (lua_isfunction(L, -1)) {
        lua_pushinteger(L, (lua_Integer)(intptr_t)lua_touserdata(L, 1));
        lua_call(L, 1, 0);
    }
    return 0;
}

static int mesh_cb(lua_State *L)
{
    event_t *ev = lua_touserdata(L, 1);
    lua_getglobal(L, "on_mesh");
    if (!lua_isfunction(L, -1)) {
        return 0;
    }
    lua_pushstring(L, ev->fromid);
    if (lh_json_decode(L, ev->json, strlen(ev->json))) {
        return 0;
    }
    lua_call(L, 2, 0);
    return 0;
}

static int exit_cb(lua_State *L)
{
    lua_getglobal(L, "on_exit");
    if (lua_isfunction(L, -1)) {
        lua_call(L, 0, 0);
    }
    return 0;
}

static void quit(badge_t *b)
{
    if (b->L && !b->failed) {
        callback(b, exit_cb, NULL);
    }
    close_app(b);
    b->exited = true;
    blog(b, "closed");
}

static void advance(int64_t ms)
{
    int64_t end = s_now + ms;
    while (s_now < end) {
        s_now += STEP_MS;
        for (int k = 0; k < s_nev; k++) {
            event_t *e = &s_ev[k];
            if (e->to < 0 || e->at > s_now) {
                continue;
            }
            event_t ev = *e;
            e->to = -1;
            e->json = NULL;
            badge_t *b = s_b[ev.to];
            if (b->L && !b->failed) {
                callback(b, ev.key >= 0 ? key_cb : mesh_cb, &ev);
            }
            free(ev.json);
            if (b->L && b->exited) {
                quit(b);
            }
        }
        int live = 0;
        for (int k = 0; k < s_nev; k++) {
            if (s_ev[k].to >= 0) {
                s_ev[live++] = s_ev[k];
            }
        }
        s_nev = live;
        for (int i = 0; i < s_n; i++) {
            badge_t *b = s_b[i];
            if (b->L && !b->failed && s_now >= b->next_tick) {
                int64_t late = s_now - b->next_tick + TICK_MS;
                b->next_tick = s_now + TICK_MS;
                callback(b, tick_cb, (void *)(intptr_t)late);
            }
            if (b->pending) {
                free(b->saved);
                b->saved = b->pending;
                b->pending = NULL;
            }
        }
    }
}

static badge_t *arg_badge(lua_State *L, int idx)
{
    lua_Integer i = luaL_checkinteger(L, idx);
    luaL_argcheck(L, i >= 1 && i <= s_n, idx, "no such badge");
    return s_b[i - 1];
}

static int d_badge(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_argcheck(L, s_n < BADGES_MAX, 1, "too many badges");
    badge_t *b = calloc(1, sizeof(*b));
    b->index = s_n;
    lua_getfield(L, 1, "app");
    snprintf(b->dir, sizeof(b->dir), "%s", luaL_checkstring(L, -1));
    lua_getfield(L, 1, "id");
    snprintf(b->id, sizeof(b->id), "%s", lua_isstring(L, -1) ? lua_tostring(L, -1) : "");
    if (!b->id[0]) {
        snprintf(b->id, sizeof(b->id), "b%05d", s_n + 1);
    }
    lua_getfield(L, 1, "owner");
    b->has_owner = lua_isstring(L, -1);
    if (b->has_owner) {
        snprintf(b->owner, sizeof(b->owner), "%s", lua_tostring(L, -1));
    }
    lua_getfield(L, 1, "store");
    b->store = lua_toboolean(L, -1);
    lua_getfield(L, 1, "data");
    if (lua_isstring(L, -1)) {
        b->saved = strdup(lua_tostring(L, -1));
    }
    lua_pop(L, 5);
    if (b->store) {
        store_compile(b, "main.lua");
        store_walk(b, "");
    }
    s_b[s_n++] = b;
    for (int i = 0; i < s_n; i++) {
        s_link[i][b->index] = s_link[b->index][i] = i != b->index;
        s_rssi[i][b->index] = s_rssi[b->index][i] = -60;
    }
    start(b);
    lua_pushinteger(L, s_n);
    return 1;
}

static int d_run(lua_State *L)
{
    advance(luaL_checkinteger(L, 1));
    return 0;
}

static int d_key(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    const char *k = luaL_checkstring(L, 2);
    int key = -1;
    for (int i = 0; i < 6; i++) {
        if (!strcmp(k, s_keys[i])) {
            key = i;
        }
    }
    luaL_argcheck(L, key >= 0, 2, "unknown key");
    if (s_nev < EVENTS_MAX) {
        event_t *e = &s_ev[s_nev++];
        memset(e, 0, sizeof(*e));
        e->at = s_now;
        e->to = b->index;
        e->from = b->index;
        e->key = key;
        e->repeat = lua_toboolean(L, 3);
    }
    return 0;
}

static int cmp_obj(const void *a, const void *c)
{
    const obj_t *x = *(const obj_t *const *)a, *y = *(const obj_t *const *)c;
    return x->y != y->y ? x->y - y->y : x->x - y->x;
}

static int d_screen(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    obj_t *sorted[OBJ_MAX];
    int n = 0, rects = 0, objs = 0;
    for (int i = 0; i < OBJ_MAX; i++) {
        obj_t *o = &b->objs[i];
        if (o->used) {
            objs++;
            rects += o->kind == RECT;
            if (!o->hidden && (o->kind == LABEL || o->kind == LIST)) {
                sorted[n++] = o;
            }
        }
    }
    qsort(sorted, (size_t)n, sizeof(sorted[0]), cmp_obj);
    lua_newtable(L);
    lua_newtable(L);
    int k = 0;
    for (int i = 0; i < n; i++) {
        obj_t *o = sorted[i];
        if (o->kind == LABEL) {
            lua_pushstring(L, o->text);
            lua_rawseti(L, -2, ++k);
        } else if (b->L) {
            lua_rawgeti(b->L, LUA_REGISTRYINDEX, o->items_ref);
            int c = (int)lua_rawlen(b->L, -1);
            for (int r = 1; r <= c; r++) {
                lua_rawgeti(b->L, -1, r);
                char row[600] = "";
                if (lua_istable(b->L, -1)) {
                    lua_getfield(b->L, -1, "title");
                    lua_getfield(b->L, -2, "sub");
                    lua_getfield(b->L, -3, "right");
                    snprintf(row, sizeof(row), "%s%s | %s | %s", r - 1 == o->sel ? "> " : "  ",
                             lua_isstring(b->L, -3) ? lua_tostring(b->L, -3) : "",
                             lua_isstring(b->L, -2) ? lua_tostring(b->L, -2) : "",
                             lua_isstring(b->L, -1) ? lua_tostring(b->L, -1) : "");
                    lua_pop(b->L, 3);
                } else {
                    snprintf(row, sizeof(row), "%s%s", r - 1 == o->sel ? "> " : "  ",
                             lua_isstring(b->L, -1) ? lua_tostring(b->L, -1) : "");
                }
                lua_pop(b->L, 1);
                lua_pushstring(L, row);
                lua_rawseti(L, -2, ++k);
            }
            lua_pop(b->L, 1);
        }
    }
    lua_setfield(L, -2, "lines");
    lua_pushstring(L, b->hint);
    lua_setfield(L, -2, "hint");
    lua_pushinteger(L, rects);
    lua_setfield(L, -2, "rects");
    lua_pushinteger(L, objs);
    lua_setfield(L, -2, "objects");
    lua_pushinteger(L, (lua_Integer)b->text_total);
    lua_setfield(L, -2, "text");
    lua_newtable(L);
    for (int i = 0; i < LED_COUNT; i++) {
        lua_pushinteger(L, b->led[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "leds");
    lua_newtable(L);
    int from = b->toast_n > 16 ? b->toast_n - 16 : 0;
    for (int i = from; i < b->toast_n; i++) {
        lua_pushstring(L, b->toasts[i % 16]);
        lua_rawseti(L, -2, i - from + 1);
    }
    lua_setfield(L, -2, "toasts");
    return 1;
}

static int d_state(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)b->mem);
    lua_setfield(L, -2, "heap");
    lua_pushinteger(L, (lua_Integer)b->peak);
    lua_setfield(L, -2, "peak");
    lua_pushboolean(L, b->mem_hit);
    lua_setfield(L, -2, "hit");
    lua_pushinteger(L, b->steps_peak);
    lua_setfield(L, -2, "steps");
    lua_pushboolean(L, b->L != NULL);
    lua_setfield(L, -2, "running");
    if (b->failed) {
        lua_pushfstring(L, "%s: %s", b->title, b->err);
        lua_setfield(L, -2, "error");
    }
    lua_pushstring(L, b->id);
    lua_setfield(L, -2, "id");
    lua_pushinteger(L, b->sent);
    lua_setfield(L, -2, "sent");
    lua_pushinteger(L, b->too_fast);
    lua_setfield(L, -2, "too_fast");
    lua_pushinteger(L, b->too_big);
    lua_setfield(L, -2, "too_big");
    lua_pushinteger(L, b->dropped);
    lua_setfield(L, -2, "dropped");
    lua_pushstring(L, b->saved ? b->saved : "");
    lua_setfield(L, -2, "data");
    lua_pushinteger(L, (lua_Integer)(b->saved ? strlen(b->saved) : 0));
    lua_setfield(L, -2, "data_bytes");
    return 1;
}

static int d_data(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    if (!b->saved || lh_json_decode(L, b->saved, strlen(b->saved))) {
        lua_newtable(L);
    }
    return 1;
}

static int d_live(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    if (!b->L) {
        return 0;
    }
    lua_gc(b->L, LUA_GCCOLLECT);
    lua_pushinteger(L, (lua_Integer)b->mem);
    return 1;
}

static int d_logs(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    lua_newtable(L);
    int from = b->log_n > LOG_MAX ? b->log_n - LOG_MAX : 0;
    for (int i = from; i < b->log_n; i++) {
        lua_pushstring(L, b->logs[i % LOG_MAX]);
        lua_rawseti(L, -2, i - from + 1);
    }
    return 1;
}

static int d_peak_reset(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    b->peak = b->mem;
    b->mem_hit = false;
    b->steps_peak = 0;
    return 0;
}

static int d_restart(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    quit(b);
    start(b);
    return 0;
}

static int d_quit(lua_State *L)
{
    quit(arg_badge(L, 1));
    return 0;
}

static int d_link(lua_State *L)
{
    badge_t *a = arg_badge(L, 1), *c = arg_badge(L, 2);
    s_link[a->index][c->index] = s_link[c->index][a->index] = lua_toboolean(L, 3);
    return 0;
}

static int d_rssi(lua_State *L)
{
    badge_t *a = arg_badge(L, 1), *c = arg_badge(L, 2);
    int v = (int)luaL_checkinteger(L, 3);
    s_rssi[a->index][c->index] = s_rssi[c->index][a->index] = v;
    return 0;
}

static int d_loss(lua_State *L)
{
    s_loss = luaL_checknumber(L, 1);
    return 0;
}

static int d_chaos(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "loss");
    s_loss = luaL_optnumber(L, -1, s_loss);
    lua_getfield(L, 1, "dup");
    s_dup = luaL_optnumber(L, -1, s_dup);
    lua_getfield(L, 1, "latency");
    s_latency = (int)luaL_optinteger(L, -1, s_latency);
    lua_getfield(L, 1, "jitter");
    s_jitter = (int)luaL_optinteger(L, -1, s_jitter);
    return 0;
}

static int d_inject(lua_State *L)
{
    badge_t *b = arg_badge(L, 1);
    post(b->index, luaL_checkstring(L, 2), luaL_checkstring(L, 3), s_now + luaL_optinteger(L, 4, 0));
    return 0;
}

static int d_latency(lua_State *L)
{
    s_latency = (int)luaL_checkinteger(L, 1);
    return 0;
}

static int d_clock(lua_State *L)
{
    s_has_time = lua_toboolean(L, 1);
    if (lua_isinteger(L, 2)) {
        s_epoch = lua_tointeger(L, 2) - s_now / 1000;
    }
    return 0;
}

static int d_now(lua_State *L)
{
    lua_pushinteger(L, s_now);
    return 1;
}

static int d_echo(lua_State *L)
{
    s_echo = lua_toboolean(L, 1);
    return 0;
}

static int d_reset(lua_State *L)
{
    for (int i = 0; i < s_n; i++) {
        close_app(s_b[i]);
        free(s_b[i]->saved);
        free(s_b[i]->pending);
        for (int k = 0; k < LOG_MAX; k++) {
            free(s_b[i]->logs[k]);
        }
        for (int k = 0; k < s_b[i]->nchunks; k++) {
            free(s_b[i]->chunks[k].data);
        }
        free(s_b[i]);
    }
    for (int k = 0; k < s_nev; k++) {
        free(s_ev[k].json);
    }
    s_n = s_nev = 0;
    s_now = 0;
    s_loss = 0;
    s_latency = 15;
    s_jitter = 10;
    s_dup = 0;
    s_has_time = true;
    s_epoch = 1793000000;
    s_rng = 0x9E3779B97F4A7C15ull ^ (uint64_t)luaL_optinteger(L, 1, 0);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: badgesim <script.lua> [args]\n");
        return 2;
    }
    const char *dir = getenv("SIM_CWD");
    if (dir) {
        chdir(dir);
    }
    lua_State *L = luaL_newstate();
    static const luaL_Reg libs[] = {
        {LUA_GNAME, luaopen_base}, {LUA_COLIBNAME, luaopen_coroutine}, {LUA_STRLIBNAME, luaopen_string},
        {LUA_TABLIBNAME, luaopen_table}, {LUA_MATHLIBNAME, luaopen_math}, {LUA_UTF8LIBNAME, luaopen_utf8},
    };
    for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]); i++) {
        luaL_requiref(L, libs[i].name, libs[i].func, 1);
        lua_pop(L, 1);
    }
    static const luaL_Reg sim[] = {
        {"badge", d_badge}, {"run", d_run}, {"key", d_key}, {"screen", d_screen}, {"state", d_state},
        {"logs", d_logs}, {"data", d_data}, {"live", d_live}, {"peak_reset", d_peak_reset}, {"restart", d_restart}, {"quit", d_quit},
        {"link", d_link}, {"rssi", d_rssi}, {"loss", d_loss}, {"latency", d_latency}, {"chaos", d_chaos}, {"inject", d_inject}, {"clock", d_clock},
        {"now", d_now}, {"echo", d_echo}, {"reset", d_reset}, {NULL, NULL},
    };
    luaL_newlib(L, sim);
    lua_setglobal(L, "sim");
    lua_newtable(L);
    for (int i = 2; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");
    if (luaL_loadfilex(L, argv[1], "t") != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }
    int code = (int)lua_tointeger(L, -1);
    lua_close(L);
    return code;
}
