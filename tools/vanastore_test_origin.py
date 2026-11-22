#!/usr/bin/env python3
"""A stand-in for ffxiprivateservers.com's addon routes, for testing VanaStore on this PC.

    vanastore_test_origin.py <folder> [--port 8765]

Serves, on 127.0.0.1 only:
    GET /api/addons?framework=vanacore              <folder>/catalog.json
    GET /api/addons/<slug>/download                 <folder>/packages/<slug>.vcaddon
    GET /api/addons/<slug>/screenshots/<N>.jpg      <folder>/shots/<slug>/<N>.jpg (any ?w= is ignored)

catalog.json is the catalog the store reads (see addons/vanacore/vanastore/catalog.lua), with two conveniences: the text
{origin} anywhere in it becomes this server's address, and an addon whose "sha256" is "auto" gets its package's real
SHA-256 and size as it is served (any other value is sent as written: that is how a wrong checksum is tested). The file
is read again on every request, so it can be edited while the game runs.

In the game:  /store origin http://127.0.0.1:8765     and, to go back:  /store origin default
"""
import argparse
import hashlib
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('folder')
parser.add_argument('--port', type=int, default=8765)
args = parser.parse_args()
ROOT = os.path.abspath(args.folder)
ORIGIN = 'http://127.0.0.1:%d' % args.port
SLUG = r'([A-Za-z0-9_.-]+)'


def package_path(slug):
    return os.path.join(ROOT, 'packages', slug + '.vcaddon')


def catalog():
    text = open(os.path.join(ROOT, 'catalog.json'), encoding='utf-8').read().replace('{origin}', ORIGIN)
    doc = json.loads(text)
    for addon in doc.get('addons', []):
        if addon.get('sha256') == 'auto':
            data = open(package_path(addon['slug']), 'rb').read()
            addon['sha256'] = hashlib.sha256(data).hexdigest()
            addon['sizeBytes'] = len(data)
    return json.dumps(doc).encode()


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, kind):
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        try:
            if path == '/api/addons':
                return self.send(200, catalog(), 'application/json')
            m = re.fullmatch('/api/addons/' + SLUG + '/download', path)
            if m:
                return self.send(200, open(package_path(m.group(1)), 'rb').read(), 'application/zip')
            m = re.fullmatch('/api/addons/' + SLUG + r'/screenshots/(\d+)\.(jpg|png)', path)
            if m:
                file = os.path.join(ROOT, 'shots', m.group(1), m.group(2) + '.' + m.group(3))
                return self.send(200, open(file, 'rb').read(), 'image/jpeg' if m.group(3) == 'jpg' else 'image/png')
        except (OSError, ValueError, KeyError) as e:
            return self.send(404, str(e).encode(), 'text/plain')
        self.send(404, b'not found', 'text/plain')


print('VanaStore test origin: %s serving %s' % (ORIGIN, ROOT), flush=True)
ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
