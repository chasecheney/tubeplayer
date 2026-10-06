"""YouTube JS challenge provider for yt-dlp backed by Apple's JavaScriptCore.

iOS apps cannot launch deno/node/bun, so this provider evaluates the yt-dlp
EJS solver scripts in-process through the JavaScriptCore C API (loaded with
ctypes). Importing this module registers the provider with yt-dlp.

For testing off-device, set TUBEPLAYER_JS_BACKEND=node to run the same
script through a node binary instead.
"""
from __future__ import annotations

import ctypes
import os
import shutil
import subprocess
import threading

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProvider,
    JsChallengeProviderError,
    JsChallengeRequest,
    register_preference,
    register_provider,
)
from yt_dlp.utils._jsruntime import JsRuntimeInfo

_JSC_PATHS = (
    '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore',
    None,  # already-loaded symbols (the app links WebKit)
)

# console.log shim: the solver prints its JSON result; collect it instead and
# make it the completion value of the script.
_PRELUDE = '''
var __tpOut = [];
globalThis.console = {
  log: function () { __tpOut.push(Array.prototype.join.call(arguments, ' ')); },
  info: function () {}, warn: function () {}, error: function () {}, debug: function () {},
};
'''
_EPILOGUE = '\n;__tpOut.join("\\n");\n'


class _JSC:
    _lock = threading.Lock()
    _lib = None
    _error = None

    @classmethod
    def lib(cls):
        with cls._lock:
            if cls._lib is None and cls._error is None:
                cls._lib, cls._error = cls._load()
            return cls._lib

    @staticmethod
    def _load():
        last_error = None
        for path in _JSC_PATHS:
            try:
                lib = ctypes.CDLL(path)
                lib.JSGlobalContextCreate  # noqa: B018 - symbol check
            except (OSError, AttributeError) as e:
                last_error = e
                continue
            vp, sz = ctypes.c_void_p, ctypes.c_size_t
            lib.JSGlobalContextCreate.argtypes = [vp]
            lib.JSGlobalContextCreate.restype = vp
            lib.JSGlobalContextRelease.argtypes = [vp]
            lib.JSGlobalContextRelease.restype = None
            lib.JSStringCreateWithUTF8CString.argtypes = [ctypes.c_char_p]
            lib.JSStringCreateWithUTF8CString.restype = vp
            lib.JSStringRelease.argtypes = [vp]
            lib.JSStringRelease.restype = None
            lib.JSStringGetMaximumUTF8CStringSize.argtypes = [vp]
            lib.JSStringGetMaximumUTF8CStringSize.restype = sz
            lib.JSStringGetUTF8CString.argtypes = [vp, ctypes.c_char_p, sz]
            lib.JSStringGetUTF8CString.restype = sz
            lib.JSEvaluateScript.argtypes = [vp, vp, vp, vp, ctypes.c_int, ctypes.POINTER(vp)]
            lib.JSEvaluateScript.restype = vp
            lib.JSValueToStringCopy.argtypes = [vp, vp, ctypes.POINTER(vp)]
            lib.JSValueToStringCopy.restype = vp
            return lib, None
        return None, last_error


def _js_string_to_py(lib, js_str):
    size = lib.JSStringGetMaximumUTF8CStringSize(js_str)
    buf = ctypes.create_string_buffer(size)
    lib.JSStringGetUTF8CString(js_str, buf, size)
    return buf.value.decode('utf-8', 'replace')


def _value_to_py(lib, ctx, value):
    exc = ctypes.c_void_p()
    js_str = lib.JSValueToStringCopy(ctx, value, ctypes.byref(exc))
    if not js_str:
        return ''
    try:
        return _js_string_to_py(lib, js_str)
    finally:
        lib.JSStringRelease(js_str)


def evaluate(script: str) -> str:
    """Run a script and return the text it printed with console.log."""
    source = _PRELUDE + script + _EPILOGUE
    if os.environ.get('TUBEPLAYER_JS_BACKEND') == 'node':
        return _evaluate_node(script)
    lib = _JSC.lib()
    if lib is None:
        raise JsChallengeProviderError(f'JavaScriptCore is not available: {_JSC._error}')
    ctx = lib.JSGlobalContextCreate(None)
    js_src = lib.JSStringCreateWithUTF8CString(source.encode('utf-8'))
    try:
        exc = ctypes.c_void_p()
        result = lib.JSEvaluateScript(ctx, js_src, None, None, 1, ctypes.byref(exc))
        if exc.value:
            raise JsChallengeProviderError(f'JavaScriptCore error: {_value_to_py(lib, ctx, exc)}')
        if not result:
            raise JsChallengeProviderError('JavaScriptCore returned no result')
        return _value_to_py(lib, ctx, result)
    finally:
        lib.JSStringRelease(js_src)
        lib.JSGlobalContextRelease(ctx)


def _evaluate_node(script: str) -> str:
    node = shutil.which('node')
    if not node:
        raise JsChallengeProviderError('node not found for test backend')
    proc = subprocess.run([node, '-'], input=script, capture_output=True, text=True, check=False)
    if proc.returncode:
        raise JsChallengeProviderError(proc.stderr.strip())
    return proc.stdout


def is_supported() -> bool:
    if os.environ.get('TUBEPLAYER_JS_BACKEND') == 'node':
        return shutil.which('node') is not None
    return _JSC.lib() is not None


@register_provider
class JavaScriptCoreJCP(EJSBaseJCP):
    PROVIDER_VERSION = '1.0.0'
    PROVIDER_NAME = 'javascriptcore'
    JS_RUNTIME_NAME = 'javascriptcore'
    BUG_REPORT_LOCATION = 'https://github.com/chasecheney/tubeplayer/issues'

    @property
    def runtime_info(self):
        if not is_supported():
            return None
        return JsRuntimeInfo(name='javascriptcore', path='', version='1.0', version_tuple=(1, 0))

    def _run_js_runtime(self, stdin: str, /) -> str:
        self.logger.debug('Running JavaScriptCore')
        return evaluate(stdin)


@register_preference(JavaScriptCoreJCP)
def _preference(provider: JsChallengeProvider, requests: list[JsChallengeRequest]) -> int:
    return 1000
