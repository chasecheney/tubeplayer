#ifndef PythonBridge_h
#define PythonBridge_h

/// Starts the embedded Python interpreter. `resource_path` is the app bundle's
/// resource directory (containing python/, app/ and app_packages/).
/// Returns 0 on success; on failure `error_out` receives a malloc'd message.
int tp_python_init(const char *resource_path, char **error_out);

/// Calls `tubeplayer_engine.<function>(json_arg)` and returns its JSON result
/// as a malloc'd UTF-8 string. Free it with tp_free. Safe to call from any thread.
char *tp_python_call(const char *function, const char *json_arg);

void tp_free(char *pointer);

#endif
