#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NOP        0xD503201Fu
#define GUARD_SPAN 0x200u
#define NEEDLE     "Cannot set LED ontime"
#define PT_LOAD    1
#define EM_AARCH64 183
#define MAXSEG     64
#define COND_MI    4
#define FCMP_D1_D0 0x1E602020u

static int fail(const char *msg) {
    fprintf(stderr, "ledpatch: %s\n", msg);
    return 1;
}

static uint8_t *g_buf;
static size_t   g_len;

static int rd_u16(size_t off, uint16_t *v) {
    if (off + 2 > g_len) return 0;
    *v = (uint16_t)(g_buf[off] | g_buf[off + 1] << 8);
    return 1;
}
static int rd_u32(size_t off, uint32_t *v) {
    if (off + 4 > g_len) return 0;
    *v = (uint32_t)g_buf[off] | (uint32_t)g_buf[off + 1] << 8 |
         (uint32_t)g_buf[off + 2] << 16 | (uint32_t)g_buf[off + 3] << 24;
    return 1;
}
static int rd_u64(size_t off, uint64_t *v) {
    uint32_t lo, hi;
    if (!rd_u32(off, &lo) || !rd_u32(off + 4, &hi)) return 0;
    *v = (uint64_t)lo | (uint64_t)hi << 32;
    return 1;
}

static struct { uint64_t vaddr, off, filesz; } g_load[MAXSEG];
static int g_nload;
static uint64_t g_text_va, g_text_off, g_text_size;

static int off_of_va(uint64_t va, uint64_t *off) {
    for (int i = 0; i < g_nload; i++)
        if (va >= g_load[i].vaddr && va < g_load[i].vaddr + g_load[i].filesz) {
            *off = g_load[i].off + (va - g_load[i].vaddr);
            return 1;
        }
    return 0;
}
static int va_of_off(uint64_t off, uint64_t *va) {
    for (int i = 0; i < g_nload; i++)
        if (off >= g_load[i].off && off < g_load[i].off + g_load[i].filesz) {
            *va = g_load[i].vaddr + (off - g_load[i].off);
            return 1;
        }
    return 0;
}

static int parse_elf(void) {
    uint8_t *e = g_buf;
    if (g_len < 64 || memcmp(e, "\x7f""ELF", 4) != 0) return fail("not an ELF file");
    if (e[4] != 2 || e[5] != 1) return fail("not little-endian ELF64");
    uint16_t machine, phnum, shnum, shstrndx, phentsize, shentsize;
    uint64_t phoff, shoff;
    if (!rd_u16(18, &machine) || machine != EM_AARCH64) return fail("not an AArch64 object");
    if (!rd_u64(32, &phoff) || !rd_u64(40, &shoff)) return fail("truncated ELF header");
    if (!rd_u16(54, &phentsize) || !rd_u16(56, &phnum) ||
        !rd_u16(58, &shentsize) || !rd_u16(60, &shnum) || !rd_u16(62, &shstrndx))
        return fail("truncated ELF header");

    for (uint16_t i = 0; i < phnum; i++) {
        uint64_t base = phoff + (uint64_t)i * phentsize;
        uint32_t type;
        if (!rd_u32(base, &type)) return fail("bad program header");
        if (type != PT_LOAD) continue;
        if (g_nload >= MAXSEG) return fail("too many PT_LOAD segments");
        uint64_t off, vaddr, filesz;
        if (!rd_u64(base + 8, &off) || !rd_u64(base + 16, &vaddr) ||
            !rd_u64(base + 32, &filesz)) return fail("bad PT_LOAD");
        if (off + filesz > g_len) return fail("PT_LOAD past end of file");
        g_load[g_nload].vaddr = vaddr;
        g_load[g_nload].off = off;
        g_load[g_nload].filesz = filesz;
        g_nload++;
    }
    if (g_nload == 0) return fail("no PT_LOAD segments");

    if (shnum == 0 || shstrndx >= shnum) return fail("no section headers");
    uint64_t shstr_off;
    if (!rd_u64(shoff + (uint64_t)shstrndx * shentsize + 24, &shstr_off))
        return fail("bad shstrtab header");
    for (uint16_t i = 0; i < shnum; i++) {
        uint64_t base = shoff + (uint64_t)i * shentsize;
        uint32_t name;
        uint64_t addr, off, size;
        if (!rd_u32(base, &name) || !rd_u64(base + 16, &addr) ||
            !rd_u64(base + 24, &off) || !rd_u64(base + 32, &size))
            return fail("bad section header");
        uint64_t np = shstr_off + name;
        if (np + 6 <= g_len && memcmp(g_buf + np, ".text", 6) == 0) {
            if (off + size > g_len) return fail(".text past end of file");
            g_text_va = addr; g_text_off = off; g_text_size = size;
            return 0;
        }
    }
    return fail(".text section not found");
}

static int64_t sext(uint64_t v, int bits) {
    uint64_t m = (uint64_t)1 << (bits - 1);
    return (int64_t)((v ^ m) - m);
}
static int is_adrp(uint32_t w, int *rd, uint64_t pc, uint64_t *page) {
    if ((w & 0x9F000000u) != 0x90000000u) return 0;
    uint64_t immlo = (w >> 29) & 3, immhi = (w >> 5) & 0x7FFFFu;
    int64_t imm = sext((immhi << 2) | immlo, 21);
    *rd = (int)(w & 0x1F);
    *page = (pc & ~0xFFFULL) + ((uint64_t)(imm << 12));
    return 1;
}
static int is_add_imm(uint32_t w, int *rd, int *rn, uint64_t *imm) {
    if ((w & 0xFF800000u) != 0x91000000u) return 0;
    uint64_t v = (w >> 10) & 0xFFF;
    if ((w >> 22) & 1) v <<= 12;
    *rn = (int)((w >> 5) & 0x1F); *rd = (int)(w & 0x1F); *imm = v;
    return 1;
}
static int is_ldr_x_imm(uint32_t w, int *rt, int *rn, uint64_t *imm) {
    if ((w & 0xFFC00000u) != 0xF9400000u) return 0;
    *imm = ((w >> 10) & 0xFFF) * 8ull;
    *rn = (int)((w >> 5) & 0x1F); *rt = (int)(w & 0x1F);
    return 1;
}
static int is_bl(uint32_t w, uint64_t pc, uint64_t *tgt) {
    if ((w & 0xFC000000u) != 0x94000000u) return 0;
    *tgt = pc + (uint64_t)(sext(w & 0x03FFFFFFu, 26) << 2);
    return 1;
}
static int is_bcond(uint32_t w, uint64_t pc, uint64_t *tgt, int *cond) {
    if ((w & 0xFF000010u) != 0x54000000u) return 0;
    *cond = (int)(w & 0xF);
    *tgt = pc + (uint64_t)(sext((w >> 5) & 0x7FFFFu, 19) << 2);
    return 1;
}

struct vec { uint64_t *p; size_t n, cap; };
static int vpush(struct vec *v, uint64_t x) {
    if (v->n == v->cap) {
        size_t nc = v->cap ? v->cap * 2 : 1024;
        uint64_t *np = realloc(v->p, nc * sizeof(uint64_t));
        if (!np) return 0;
        v->p = np; v->cap = nc;
    }
    v->p[v->n++] = x;
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) return fail("usage: ledpatch <in.so> <out.so>");

    FILE *f = fopen(argv[1], "rb");
    if (!f) return fail("cannot open input");
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return fail("seek failed"); }
    long sz = ftell(f);
    if (sz <= 0 || sz > (long)512 * 1024 * 1024) { fclose(f); return fail("bad input size"); }
    g_len = (size_t)sz;
    g_buf = malloc(g_len);
    if (!g_buf) { fclose(f); return fail("out of memory"); }
    rewind(f);
    if (fread(g_buf, 1, g_len, f) != g_len) { fclose(f); return fail("short read"); }
    fclose(f);

    if (parse_elf()) return 1;

    size_t need = strlen(NEEDLE), str_off = 0, hits = 0;
    if (g_len >= need)
        for (size_t i = 0; i + need <= g_len; i++)
            if (memcmp(g_buf + i, NEEDLE, need) == 0) { str_off = i; if (++hits > 1) break; }
    if (hits != 1) return fail("format string not unique");
    uint64_t str_va;
    if (!va_of_off(str_off, &str_va)) return fail("string not in a loaded segment");

    struct vec blsite = {0}, bltgt = {0};
    uint64_t page[32]; int pagev[32];
    memset(pagev, 0, sizeof(pagev));
    uint64_t ref_min = 0; int have_ref = 0;
    uint64_t text_end = g_text_off + g_text_size;

    for (uint64_t off = g_text_off; off + 4 <= text_end; off += 4) {
        uint32_t w;
        if (!rd_u32(off, &w)) break;
        uint64_t pc = g_text_va + (off - g_text_off);
        int rd, rn; uint64_t imm, tgt, pg;

        if (is_adrp(w, &rd, pc, &pg)) { page[rd] = pg; pagev[rd] = 1; }
        else if (is_add_imm(w, &rd, &rn, &imm)) {
            if (pagev[rn] && page[rn] + imm == str_va) { if (!have_ref || pc < ref_min) ref_min = pc; have_ref = 1; }
        } else if (is_ldr_x_imm(w, &rd, &rn, &imm)) {
            if (pagev[rn] && page[rn] + imm == str_va) { if (!have_ref || pc < ref_min) ref_min = pc; have_ref = 1; }
        }
        if (is_bl(w, pc, &tgt))
            if (!vpush(&blsite, pc) || !vpush(&bltgt, tgt)) return fail("out of memory");
    }

    if (!have_ref) return fail("format string is never referenced");

    uint64_t F = 0; int haveF = 0;
    for (size_t i = 0; i < bltgt.n; i++)
        if (bltgt.p[i] <= ref_min && (!haveF || bltgt.p[i] > F)) { F = bltgt.p[i]; haveF = 1; }
    if (!haveF) return fail("cannot locate fatal formatter entry");

    uint64_t C = 0; size_t ncall = 0;
    for (size_t i = 0; i < bltgt.n; i++)
        if (bltgt.p[i] == F) { C = blsite.p[i]; ncall++; }
    if (ncall != 1) return fail("fatal formatter is not called from exactly one site");

    uint64_t A = 0; unsigned nguard = 0;
    for (uint64_t off = g_text_off; off + 4 <= text_end; off += 4) {
        uint32_t w;
        if (!rd_u32(off, &w)) break;
        uint64_t pc = g_text_va + (off - g_text_off);
        int cond; uint64_t tgt;
        if (!is_bcond(w, pc, &tgt, &cond) || cond != COND_MI) continue;
        if (!(pc < tgt && tgt <= C && C <= tgt + GUARD_SPAN)) continue;
        int fcmp = 0;
        for (uint64_t k = 1; k <= 3 && off >= g_text_off + k * 4; k++) {
            uint32_t fw;
            if (rd_u32(off - k * 4, &fw) && fw == FCMP_D1_D0) { fcmp = 1; break; }
        }
        if (fcmp) { A = pc; nguard++; }
    }
    if (nguard != 1) return fail("LED-cap guard branch not uniquely identified");

    uint64_t poff;
    if (!off_of_va(A, &poff)) return fail("guard not in a loaded segment");
    uint32_t cur; int cc; uint64_t ct;
    if (!rd_u32(poff, &cur) || !is_bcond(cur, A, &ct, &cc) || cc != COND_MI)
        return fail("guard site is not a b.mi (unexpected)");
    g_buf[poff + 0] = (uint8_t)(NOP);
    g_buf[poff + 1] = (uint8_t)(NOP >> 8);
    g_buf[poff + 2] = (uint8_t)(NOP >> 16);
    g_buf[poff + 3] = (uint8_t)(NOP >> 24);

    uint32_t chk;
    if (!rd_u32(poff, &chk) || chk != NOP) return fail("post-patch verify failed");

    free(blsite.p); free(bltgt.p);

    FILE *o = fopen(argv[2], "wb");
    if (!o) return fail("cannot open output");
    if (fwrite(g_buf, 1, g_len, o) != g_len) { fclose(o); return fail("short write"); }
    if (fclose(o) != 0) return fail("close/flush failed");

    printf("ledpatch: OK  string@%#llx ref@%#llx formatter@%#llx caller@%#llx guard(b.mi)@%#llx -> nop\n",
           (unsigned long long)str_va, (unsigned long long)ref_min,
           (unsigned long long)F, (unsigned long long)C, (unsigned long long)A);
    return 0;
}
