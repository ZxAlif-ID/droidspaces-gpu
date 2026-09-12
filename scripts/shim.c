/* shim.c — export the __isoc23_* symbols that glibc 2.38 added.
 *
 * Binaries/libraries built on Ubuntu noble (glibc 2.38) reference the new
 * C23 strto* / scan* entry points. On jammy (glibc 2.35) those symbols do
 * not exist, so the dynamic linker refuses to load them. This shim exports
 * the same names with semantics identical to the classic functions
 * (glibc's C23 variants only changed hex-float parsing corner cases that
 * no driver code path relies on).
 *
 * Build:  cc -shared -fPIC -O2 -o shim.so shim.c
 * Use:    LD_PRELOAD=/opt/turnip/shim.so
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

int __isoc23_sscanf(const char *s, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vsscanf(s, fmt, ap);
    va_end(ap);
    return r;
}
int __isoc23_scanf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vscanf(fmt, ap);
    va_end(ap);
    return r;
}
int __isoc23_fscanf(FILE *f, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vfscanf(f, fmt, ap);
    va_end(ap);
    return r;
}
long __isoc23_strtol(const char *n, char **e, int b) { return strtol(n, e, b); }
long long __isoc23_strtoll(const char *n, char **e, int b) { return strtoll(n, e, b); }
unsigned long __isoc23_strtoul(const char *n, char **e, int b) { return strtoul(n, e, b); }
unsigned long long __isoc23_strtoull(const char *n, char **e, int b) { return strtoull(n, e, b); }
