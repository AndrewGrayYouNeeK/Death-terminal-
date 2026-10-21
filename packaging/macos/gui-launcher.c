/* Mach-O stand-in for Contents/MacOS/deathterminal-gui.
   Finder launches CFBundleExecutable with no arguments. The unsigned bundle
   uses a shell script for that; notarization rejects a non-Mach-O main
   executable, so the sign step compiles this over the script. It execs
   deathterminal --gui and forwards any extra arguments. */
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char self[PATH_MAX];
    uint32_t size = (uint32_t)sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) return 127;

    char *resolved = realpath(self, NULL);
    if (resolved == NULL) return 127;
    char *slash = strrchr(resolved, '/');
    if (slash == NULL) {
        free(resolved);
        return 127;
    }
    *slash = '\0';

    char bin[PATH_MAX];
    int n = snprintf(bin, sizeof(bin), "%s/deathterminal", resolved);
    free(resolved);
    if (n < 0 || (size_t)n >= sizeof(bin)) return 127;

    /* args: bin, --gui, argv[1..], NULL */
    char **args = calloc((size_t)argc + 2, sizeof(char *));
    if (args == NULL) return 127;
    args[0] = bin;
    args[1] = "--gui";
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
    args[argc + 1] = NULL;

    execv(bin, args);
    perror("deathterminal");
    free(args);
    return 127;
}
