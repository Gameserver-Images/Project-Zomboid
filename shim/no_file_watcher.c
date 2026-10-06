// Preloaded into the game when it would run out of inotify watches, which stops it while it starts.
// The JDK's watches succeed without being added, so the game's file watcher runs but sees no change
// and uses none of the host's watches. Build 41 can't cope with a missing WatchService, so this keeps
// the WatchService and only fakes its watches. Other code in the process gets real watches.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
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

int inotify_add_watch(int fd, const char *path, uint32_t mask)
{
    // Counts down, away from the descriptors the kernel hands out, so each fake watch is its own key.
    static int next = INT_MAX;
    static int (*real)(int, const char *, uint32_t);

    if (from_jdk(__builtin_return_address(0)))
        return __atomic_fetch_sub(&next, 1, __ATOMIC_RELAXED);
    if (!real)
        real = (int (*)(int, const char *, uint32_t))dlsym(RTLD_NEXT, "inotify_add_watch");
    return real(fd, path, mask);
}
