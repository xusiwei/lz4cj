// C-side reference: extDict boundary-spanning match-copy probe for Cangjie
// cross-validation (provenance of lz4DecompressExtDictSpanningTest in
// src/lz4_test.cj, M3a Task 5). Handcrafted streams against dict "ABCDEFGH"
// exercise the match that starts in the external dictionary and stretches
// into the current block (lz4.c L2199-2208 fast / L2389-2403 safe):
//   s5/s8: 2 literals, offset 4 (match = 2 bytes before lowPrefix -> dict[6]),
//          matchLen 5/8, tail "12345";
//   v3:    first-sequence spanning match with op == 0 (restSize 6 > op 2,
//          overlap byte-copy inside the fast loop's extDict branch).
// Stream construction must match spanStream()/v3 in src/lz4_test.cj
// byte-for-byte. Expected: s5 -> 12 "xyGHxyG12345", s8 -> 15
// "xyGHxyGHxy12345" (identical across fast cap>=64 / safe 14..63 loops);
// caps 13/12 -> -2 (last-run margin), s8 cap 14 -> -6 (match restriction);
// partial targets clamp mid-match (6 -> "xyGHxy", 4 -> "xyGH"); v3 -> 48
// ("GHGHGHGH" + 'a'..'n'), cap 31 -> negative.
// Build: cc -O2 -I$HOME/lz4/lib scripts/span_probe.c $HOME/lz4/lib/lz4.c \
//        $HOME/lz4/lib/xxhash.c -o scripts/span_probe
#include <stdio.h>
#include <string.h>
#include "lz4.h"

static const unsigned char dict[8] = { 'A','B','C','D','E','F','G','H' };

/* token(litLen=2, ml-4=nib), 'x','y', offset 4, last-lits 5, "12345" */
static void mk_s(unsigned char* s, unsigned char nib) {
    s[0] = (unsigned char)((2u << 4) | nib);
    s[1] = 'x'; s[2] = 'y';
    s[3] = 0x04; s[4] = 0x00;
    s[5] = 0x50;
    for (int i = 0; i < 5; i++) s[6 + i] = (unsigned char)('1' + i);
}

int main(void) {
    unsigned char s5[11], s8[11], dst[128];
    mk_s(s5, 1);   /* ml = 5 */
    mk_s(s8, 4);   /* ml = 8 */

    /* full decode, fast (cap >= 64) and safe (14..63) spanning loops */
    int caps5[3] = { 128, 63, 14 };
    for (int i = 0; i < 3; i++) {
        memset(dst, 0, sizeof(dst));
        int r = LZ4_decompress_safe_usingDict((const char*)s5, (char*)dst, 11,
                                              caps5[i], (const char*)dict, 8);
        printf("s5 cap=%3d: r=%2d out=%.*s (want 12 xyGHxyG12345)\n",
               caps5[i], r, r > 0 ? r : 0, dst);
    }
    int caps8[2] = { 128, 31 };
    for (int i = 0; i < 2; i++) {
        memset(dst, 0, sizeof(dst));
        int r = LZ4_decompress_safe_usingDict((const char*)s8, (char*)dst, 11,
                                              caps8[i], (const char*)dict, 8);
        printf("s8 cap=%3d: r=%2d out=%.*s (want 15 xyGHxyGHxy12345)\n",
               caps8[i], r, r > 0 ? r : 0, dst);
    }

    /* must-be-last-run margin (oend-MFLIMIT) and match restriction errors */
    printf("s5 cap=13: r=%d (want -2)\n",
           LZ4_decompress_safe_usingDict((const char*)s5, (char*)dst, 11, 13,
                                         (const char*)dict, 8));
    printf("s5 cap=12: r=%d (want -2)\n",
           LZ4_decompress_safe_usingDict((const char*)s5, (char*)dst, 11, 12,
                                         (const char*)dict, 8));
    printf("s8 cap=14: r=%d (want -6)\n",
           LZ4_decompress_safe_usingDict((const char*)s8, (char*)dst, 11, 14,
                                         (const char*)dict, 8));

    /* short-tail stream (< LASTLITERALS after match) -> -2 at any capacity */
    unsigned char bad[9] = { 0x21, 'x', 'y', 0x04, 0x00, 0x30, '1','2','3' };
    printf("bad cap=72: r=%d (want -2)\n",
           LZ4_decompress_safe_usingDict((const char*)bad, (char*)dst, 9, 72,
                                         (const char*)dict, 8));

    /* partial + extDict: target clamps mid-match (length = min(ml, oend-op)) */
    memset(dst, 0, sizeof(dst));
    int p6 = LZ4_decompress_safe_partial_usingDict((const char*)s8, (char*)dst,
                 11, 128, 6, (const char*)dict, 8);
    printf("partial s8 t=6: r=%d out=%.*s (want 6 xyGHxy)\n", p6, p6 > 0 ? p6 : 0, dst);
    memset(dst, 0, sizeof(dst));
    int p4 = LZ4_decompress_safe_partial_usingDict((const char*)s5, (char*)dst,
                 11, 128, 4, (const char*)dict, 8);
    printf("partial s5 t=4: r=%d out=%.*s (want 4 xyGH)\n", p4, p4 > 0 ? p4 : 0, dst);

    /* v3: first-sequence spanning match with op == 0 (fast extDict branch):
       token(litLen 0, ml 8), offset 2 (dict tail 2), 0xF0/ext 25 + 40 lits */
    unsigned char v3[45];
    size_t c = 0;
    memset(v3, 0, sizeof(v3));
    v3[c++] = 0x04;
    v3[c++] = 0x02; v3[c++] = 0x00;
    v3[c++] = 0xF0; v3[c++] = 40 - 15;
    for (int i = 0; i < 40; i++) v3[c++] = (unsigned char)('a' + (i % 26));
    int capsV3[2] = { 128, 63 };
    for (int i = 0; i < 2; i++) {
        memset(dst, 0, sizeof(dst));
        int r = LZ4_decompress_safe_usingDict((const char*)v3, (char*)dst,
                                              (int)c, capsV3[i], (const char*)dict, 8);
        printf("v3 cap=%3d: r=%2d out=%.*s (want 48 GHGHGHGH + a..n)\n",
               capsV3[i], r, r > 0 ? r : 0, dst);
    }
    memset(dst, 0, sizeof(dst));
    int r31 = LZ4_decompress_safe_usingDict((const char*)v3, (char*)dst,
                                            (int)c, 31, (const char*)dict, 8);
    printf("v3 cap=31: r=%d (want < 0)\n", r31);
    return 0;
}
