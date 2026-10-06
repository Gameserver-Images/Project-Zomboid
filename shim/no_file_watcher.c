// Preloaded into the game when it would run out of inotify watches: the game stops when a watch
// can't be added, but runs fine without file watching when the JDK can't create a WatchService.
// Only the JDK's own calls fail; any other code in the process gets real inotify instances.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/inotify.h>

static int from_jdk(const void *caller)
{
    Dl_info info;
    const char *name;

    if (!dladdr(caller, &info) || !info.dli_fname)
        return 0;
    name = strrchr(info.dli_fname, '/');
    return strcmp(name ? name + 1 : info.dli_fname, "libnio.so") == 0;
}

int inotify_init(void)
{
    static int (*real)(void);

    if (from_jdk(__builtin_return_address(0))) {
        errno = EMFILE;
        return -1;
    }
    if (!real)
        real = (int (*)(void))dlsym(RTLD_NEXT, "inotify_init");
    return real();
}

int inotify_init1(int flags)
{
    static int (*real)(int);

    if (from_jdk(__builtin_return_address(0))) {
        errno = EMFILE;
        return -1;
    }
    if (!real)
        real = (int (*)(int))dlsym(RTLD_NEXT, "inotify_init1");
    return real(flags);
}
