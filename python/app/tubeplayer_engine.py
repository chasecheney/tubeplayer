"""TubePlayer's bridge to yt-dlp.

Every public function takes one JSON string and returns one JSON string, so
the native side only needs a single "call function by name" entry point.
Responses are {"ok": true, ...} or {"ok": false, "error": "..."}.

Downloads run on Python threads; the app polls `status` for progress and
calls `cancel` to stop a job (partial files are removed).
"""
from __future__ import annotations

import functools
import glob
import json
import os
import sys
import threading
import time
import traceback
import urllib.request
import zipfile

_state = {
    'support_dir': None,
    'ready': False,
}
_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()
_info_cache: dict[str, tuple[float, dict]] = {}
_INFO_TTL = 60 * 60  # stream URLs normally stay valid for several hours


class Cancelled(Exception):
    pass


def _api(func):
    @functools.wraps(func)
    def wrapper(arg: str = '{}') -> str:
        try:
            params = json.loads(arg) if arg else {}
            result = func(params) or {}
            result.setdefault('ok', True)
        except Exception as e:  # report every failure to the app
            result = {'ok': False, 'error': _clean_error(e), 'trace': traceback.format_exc()}
        return json.dumps(result)
    return wrapper


def _clean_error(e: Exception) -> str:
    msg = str(e) or e.__class__.__name__
    for prefix in ('ERROR: ', '[youtube] '):
        msg = msg.replace(prefix, '')
    return msg.strip()


# ---------------------------------------------------------------- setup

def _updates_dir() -> str:
    return os.path.join(_state['support_dir'], 'yt-dlp-updates')


@_api
def setup(params):
    """Prepare sys.path (preferring a downloaded yt-dlp update) and import yt-dlp."""
    support_dir = params['support_dir']
    os.makedirs(support_dir, exist_ok=True)
    _state['support_dir'] = support_dir
    os.environ.setdefault('XDG_CACHE_HOME', os.path.join(support_dir, 'cache'))

    manifest = os.path.join(_updates_dir(), 'current.json')
    if os.path.exists(manifest):
        try:
            with open(manifest) as f:
                wheels = json.load(f).get('wheels', [])
            paths = [os.path.join(_updates_dir(), w) for w in wheels]
            if paths and all(os.path.exists(p) for p in paths):
                for p in reversed(paths):
                    sys.path.insert(0, p)
        except Exception:
            pass

    import yt_dlp  # noqa: F401
    import tubeplayer_jsc  # noqa: F401  registers the JavaScriptCore provider
    _state['ready'] = True
    return {'version': _ytdlp_version()}


def _ytdlp_version() -> str:
    from yt_dlp.version import __version__
    return __version__


@_api
def version(params):
    import tubeplayer_jsc
    return {'version': _ytdlp_version(), 'javascriptcore': tubeplayer_jsc.is_supported()}


# ---------------------------------------------------------------- extraction

def _base_params(**extra) -> dict:
    params = {
        'quiet': True,
        'no_warnings': True,
        'noprogress': True,
        'noplaylist': True,
        'socket_timeout': 20,
        'retries': 5,
        'fragment_retries': 10,
        'cachedir': os.path.join(_state['support_dir'] or '.', 'cache', 'yt-dlp'),
        # The JavaScriptCore provider replaces deno; fall back to fetching
        # the solver script from GitHub if the bundled one is missing.
        'js_runtimes': {},
        'remote_components': {'ejs:github'},
    }
    params.update(extra)
    return params


def _format_selector(max_height: int, prefer_compatible: bool) -> str:
    h = f'[height<={max_height}]'
    if prefer_compatible:
        return (
            f'bv*{h}[vcodec^=avc1]+ba[ext=m4a]/'
            f'bv*{h}[ext=mp4]+ba[ext=m4a]/'
            f'bv*{h}+ba/b{h}/bv*+ba/b')
    return f'bv*{h}+ba/b{h}/bv*+ba/b'


def _summarize_format(f: dict | None) -> dict | None:
    if not f:
        return None
    return {
        'format_id': f.get('format_id'),
        'url': f.get('url'),
        'ext': f.get('ext'),
        'protocol': f.get('protocol'),
        'width': f.get('width'),
        'height': f.get('height'),
        'vcodec': f.get('vcodec'),
        'acodec': f.get('acodec'),
        'filesize': f.get('filesize') or f.get('filesize_approx'),
        'http_headers': f.get('http_headers') or {},
    }


def _pick_thumbnail(info: dict) -> str | None:
    thumbs = [t for t in (info.get('thumbnails') or []) if t.get('url')]
    jpgs = [t for t in thumbs if '.jpg' in t['url'].split('?')[0]]
    pool = jpgs or thumbs
    if pool:
        best = max(pool, key=lambda t: (t.get('preference') or 0, t.get('width') or 0))
        return best['url']
    return info.get('thumbnail')


def _key_for(info: dict) -> str:
    return f"{(info.get('extractor_key') or 'site').lower()}-{info.get('id')}"


def _extract(url: str, max_height: int, prefer_compatible: bool, use_cache: bool = True) -> dict:
    cache_key = f'{url}|{max_height}|{prefer_compatible}'
    cached = _info_cache.get(cache_key)
    if use_cache and cached and time.time() - cached[0] < _INFO_TTL:
        return cached[1]

    from yt_dlp import YoutubeDL
    with YoutubeDL(_base_params(format=_format_selector(max_height, prefer_compatible))) as ydl:
        info = ydl.extract_info(url, download=False)
        info = ydl.sanitize_info(info)
    if info.get('_type') in ('playlist', 'multi_video'):
        entries = [e for e in (info.get('entries') or []) if e]
        if not entries:
            raise ValueError('No playable video found on this page')
        info = entries[0]
    _info_cache[cache_key] = (time.time(), info)
    return info


@_api
def extract(params):
    """Resolve a page URL to stream URLs. Returns video (+ optional separate audio)."""
    info = _extract(params['url'], int(params.get('max_height', 1080)),
                    bool(params.get('prefer_compatible', True)))
    requested = info.get('requested_formats')
    if requested:
        video = next((f for f in requested if f.get('vcodec') not in (None, 'none')), requested[0])
        audio = next((f for f in requested if f is not video), None)
    else:
        video, audio = info, None
    return {
        'key': _key_for(info),
        'id': info.get('id'),
        'title': info.get('title') or 'Untitled',
        'uploader': info.get('uploader') or info.get('channel'),
        'duration': info.get('duration'),
        'thumbnail': _pick_thumbnail(info),
        'webpage_url': info.get('webpage_url') or params['url'],
        'extractor': info.get('extractor_key'),
        'is_live': bool(info.get('is_live')),
        'video': _summarize_format(video),
        'audio': _summarize_format(audio),
    }


# ---------------------------------------------------------------- downloads

def _set_job(job_id: str, **fields):
    with _jobs_lock:
        _jobs.setdefault(job_id, {}).update(fields)


def _remove_partials(folder: str, stem: str):
    for path in glob.glob(os.path.join(folder, glob.escape(stem) + '*')):
        try:
            os.remove(path)
        except OSError:
            pass


@_api
def start_download(params):
    job_id = params['job_id']
    with _jobs_lock:
        existing = _jobs.get(job_id)
        if existing and existing.get('state') in ('queued', 'extracting', 'downloading'):
            return {'job_id': job_id}
        _jobs[job_id] = {
            'job_id': job_id, 'state': 'queued', 'progress': 0.0,
            'downloaded': 0, 'total': None, 'speed': None, 'eta': None,
            'cancel': threading.Event(), 'files': {}, 'error': None,
        }
    threading.Thread(target=_run_download, args=(job_id, params), daemon=True,
                     name=f'download-{job_id}').start()
    return {'job_id': job_id}


def _run_download(job_id: str, params: dict):
    folder = params['folder']
    os.makedirs(folder, exist_ok=True)
    cancel: threading.Event = _jobs[job_id]['cancel']
    try:
        _set_job(job_id, state='extracting')
        info = _extract(params['url'], int(params.get('max_height', 1080)),
                        bool(params.get('prefer_compatible', True)))
        if cancel.is_set():
            raise Cancelled
        if info.get('is_live'):
            raise ValueError('Live streams can be watched but not downloaded')

        requested = info.get('requested_formats') or [info]
        parts = []
        for f in requested:
            is_video = f.get('vcodec') not in (None, 'none') or len(requested) == 1
            role = 'video' if is_video and not any(p[0] == 'video' for p in parts) else 'audio'
            parts.append((role, f))

        sizes = {role: (f.get('filesize') or f.get('filesize_approx') or 0) for role, f in parts}
        done_bytes = {role: 0 for role, _ in parts}
        _set_job(job_id, state='downloading', total=sum(sizes.values()) or None)

        from yt_dlp import YoutubeDL

        for role, fmt in parts:
            ext = fmt.get('ext') or 'mp4'
            if fmt.get('protocol', '').startswith('m3u8'):
                ext = 'mp4' if ext in ('mp4', 'm3u8') else ext
            filename = f'{role}.{ext}'
            path = os.path.join(folder, filename)

            def hook(d, role=role):
                if cancel.is_set():
                    raise Cancelled
                if d.get('status') == 'downloading':
                    total_role = d.get('total_bytes') or d.get('total_bytes_estimate')
                    if total_role:
                        sizes[role] = total_role
                    done_bytes[role] = d.get('downloaded_bytes') or 0
                    total = sum(sizes.values())
                    done = sum(done_bytes.values())
                    _set_job(job_id, downloaded=done, total=total or None,
                             progress=(done / total) if total else 0.0,
                             speed=d.get('speed'), eta=d.get('eta'))

            ydl_params = _base_params(progress_hooks=[hook], nopart=False,
                                      continuedl=True, overwrites=True)
            with YoutubeDL(ydl_params) as ydl:
                new_info = dict(info)
                new_info.update(fmt)
                new_info.pop('requested_formats', None)
                ok = ydl.dl(path, new_info)
            if cancel.is_set():
                raise Cancelled
            if not ok or not os.path.exists(path):
                raise ValueError(f'{role} download failed')
            with _jobs_lock:
                _jobs[job_id]['files'][role] = filename
                if sizes[role] == 0:
                    sizes[role] = os.path.getsize(path)
                done_bytes[role] = sizes[role]

        thumb_url = _pick_thumbnail(info)
        if thumb_url:
            try:
                req = urllib.request.Request(thumb_url, headers={'User-Agent': 'Mozilla/5.0'})
                with _urlopen(req) as r:
                    data = r.read()
                thumb_name = 'thumb.jpg' if data[:3] == b'\xff\xd8\xff' else 'thumb.img'
                with open(os.path.join(folder, thumb_name), 'wb') as fh:
                    fh.write(data)
                with _jobs_lock:
                    _jobs[job_id]['files']['thumbnail'] = thumb_name
            except Exception:
                pass

        meta = {
            'key': _key_for(info), 'title': info.get('title'),
            'uploader': info.get('uploader') or info.get('channel'),
            'duration': info.get('duration'), 'webpage_url': info.get('webpage_url'),
            'files': _jobs[job_id]['files'],
        }
        with open(os.path.join(folder, 'info.json'), 'w') as fh:
            json.dump(meta, fh)
        _set_job(job_id, state='finished', progress=1.0, meta=meta)
    except Cancelled:
        _remove_partials(folder, '')
        _set_job(job_id, state='cancelled')
    except Exception as e:
        _remove_partials(folder, 'video.')
        _remove_partials(folder, 'audio.')
        _set_job(job_id, state='failed', error=_clean_error(e))


def _urlopen(req):
    try:
        import certifi
        import ssl
        ctx = ssl.create_default_context(cafile=certifi.where())
        return urllib.request.urlopen(req, timeout=30, context=ctx)
    except ImportError:
        return urllib.request.urlopen(req, timeout=30)


@_api
def cancel(params):
    job_id = params['job_id']
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job:
            job['cancel'].set()
            if job['state'] in ('finished', 'failed', 'cancelled'):
                _jobs.pop(job_id, None)
    return {}


@_api
def status(params):
    with _jobs_lock:
        jobs = [{k: v for k, v in j.items() if k != 'cancel'} for j in _jobs.values()]
        # Report finished/failed/cancelled jobs once, then forget them.
        for j in list(_jobs.values()):
            if j['state'] in ('finished', 'failed', 'cancelled'):
                _jobs.pop(j['job_id'], None)
    return {'jobs': jobs}


# ---------------------------------------------------------------- updates

def _download_wheel(package: str) -> tuple[str, str]:
    req = urllib.request.Request(f'https://pypi.org/pypi/{package}/json',
                                 headers={'User-Agent': 'TubePlayer'})
    with _urlopen(req) as r:
        data = json.load(r)
    version = data['info']['version']
    wheel = next(u for u in data['urls']
                 if u['packagetype'] == 'bdist_wheel' and u['filename'].endswith('-py3-none-any.whl'))
    os.makedirs(_updates_dir(), exist_ok=True)
    target = os.path.join(_updates_dir(), wheel['filename'])
    if not os.path.exists(target):
        tmp = target + '.part'
        with _urlopen(urllib.request.Request(wheel['url'], headers={'User-Agent': 'TubePlayer'})) as r, \
                open(tmp, 'wb') as fh:
            fh.write(r.read())
        zipfile.ZipFile(tmp).testzip()
        os.replace(tmp, target)
    return version, wheel['filename']


def _vtuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split('.') if x.isdigit())


@_api
def update(params):
    """Download the newest yt-dlp (and its solver scripts) from PyPI.

    Takes effect the next time the app launches.
    """
    current = _ytdlp_version()
    version, ytdlp_wheel = _download_wheel('yt-dlp')
    if _vtuple(version) <= _vtuple(current) and not params.get('force'):
        return {'updated': False, 'version': current}
    _, ejs_wheel = _download_wheel('yt-dlp-ejs')
    with open(os.path.join(_updates_dir(), 'current.json'), 'w') as fh:
        json.dump({'version': version, 'wheels': [ytdlp_wheel, ejs_wheel]}, fh)
    keep = {ytdlp_wheel, ejs_wheel, 'current.json'}
    for name in os.listdir(_updates_dir()):
        if name not in keep:
            try:
                os.remove(os.path.join(_updates_dir(), name))
            except OSError:
                pass
    return {'updated': True, 'version': version, 'previous': current}


@_api
def reset_update(params):
    path = os.path.join(_updates_dir(), 'current.json')
    if os.path.exists(path):
        os.remove(path)
    return {}
