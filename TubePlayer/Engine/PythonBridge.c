#include "PythonBridge.h"

#if __has_include(<Python/Python.h>)
#include <Python/Python.h>
#else
#include <Python.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static PyObject *engine_module = NULL;

static char *copy_string(const char *s) {
    size_t n = strlen(s) + 1;
    char *out = malloc(n);
    if (out) memcpy(out, s, n);
    return out;
}

static char *format_error(const char *message) {
    // JSON-escape enough for an error string.
    size_t len = strlen(message);
    char *escaped = malloc(len * 2 + 64);
    if (!escaped) return NULL;
    char *p = escaped;
    p += sprintf(p, "{\"ok\": false, \"error\": \"");
    for (size_t i = 0; i < len; i++) {
        char c = message[i];
        if (c == '"' || c == '\\') { *p++ = '\\'; *p++ = c; }
        else if (c == '\n') { *p++ = '\\'; *p++ = 'n'; }
        else if ((unsigned char)c >= 0x20) { *p++ = c; }
    }
    p += sprintf(p, "\"}");
    return escaped;
}

/// Describes the pending Python exception (and clears it).
static char *current_exception_message(const char *fallback) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return copy_string(fallback);
    char *result = NULL;
    PyObject *text = PyObject_Str(exc);
    if (text) {
        const char *utf8 = PyUnicode_AsUTF8(text);
        if (utf8) {
            size_t n = strlen(fallback) + strlen(utf8) + 4;
            result = malloc(n);
            if (result) snprintf(result, n, "%s: %s", fallback, utf8);
        }
        Py_DECREF(text);
    }
    PyErr_Clear();
    Py_DECREF(exc);
    return result ? result : copy_string(fallback);
}

static int add_path(PyObject *sys_path, const char *path, int front) {
    PyObject *item = PyUnicode_FromString(path);
    if (!item) return -1;
    int rc = front ? PyList_Insert(sys_path, 0, item) : PyList_Append(sys_path, item);
    Py_DECREF(item);
    return rc;
}

int tp_python_init(const char *resource_path, char **error_out) {
    if (Py_IsInitialized()) return 0;

    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;
    char path[4096];

    setenv("NO_COLOR", "1", 1);
    setenv("PYTHON_COLORS", "0", 1);

    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) goto status_error;

    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
#if PY_VERSION_HEX >= 0x030E0000 && defined(__APPLE__)
    config.use_system_logger = 1;
#endif

    snprintf(path, sizeof(path), "%s/python", resource_path);
    status = PyConfig_SetBytesString(&config, &config.home, path);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); goto status_error; }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) goto status_error;

    // app_packages is a site dir (so .pth files are honoured); app/ goes first on sys.path.
    PyObject *site = PyImport_ImportModule("site");
    PyObject *sys_path = PySys_GetObject("path");  // borrowed
    if (!site || !sys_path) goto python_error;
    snprintf(path, sizeof(path), "%s/app_packages", resource_path);
    PyObject *result = PyObject_CallMethod(site, "addsitedir", "s", path);
    Py_DECREF(site);
    if (!result) goto python_error;
    Py_DECREF(result);
    snprintf(path, sizeof(path), "%s/app", resource_path);
    if (add_path(sys_path, path, 1) != 0) goto python_error;

    engine_module = PyImport_ImportModule("tubeplayer_engine");
    if (!engine_module) goto python_error;

    // Release the GIL so worker threads and other callers can run.
    PyEval_SaveThread();
    return 0;

status_error:
    if (error_out) *error_out = copy_string(status.err_msg ? status.err_msg : "Python failed to start");
    return -1;

python_error:
    if (error_out) *error_out = current_exception_message("Python setup failed");
    if (Py_IsInitialized()) PyEval_SaveThread();
    return -1;
}

char *tp_python_call(const char *function, const char *json_arg) {
    if (!Py_IsInitialized() || !engine_module) {
        return format_error("Python is not running");
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    char *output = NULL;

    PyObject *func = PyObject_GetAttrString(engine_module, function);
    if (func && PyCallable_Check(func)) {
        PyObject *result = PyObject_CallFunction(func, "s", json_arg ? json_arg : "{}");
        if (result) {
            const char *utf8 = PyUnicode_Check(result) ? PyUnicode_AsUTF8(result) : NULL;
            output = utf8 ? copy_string(utf8) : format_error("Engine returned a non-string result");
            Py_DECREF(result);
        }
    }
    Py_XDECREF(func);

    if (!output) {
        char *message = current_exception_message(function);
        output = format_error(message ? message : function);
        free(message);
    }
    PyGILState_Release(gil);
    return output;
}

void tp_free(char *pointer) {
    free(pointer);
}
