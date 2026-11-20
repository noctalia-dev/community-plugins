#!/usr/bin/env python3
"""Host-owned local IPC bridge for Hyprland, Mango and Sway.

Uses only public UNIX-socket protocols and the Python standard library. No UI,
network requests, files written, background daemon, or polling of window lists.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import selectors
import socket
import struct
import sys
import time
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024
MAX_ITEMS = 8192
FRAME_BYTES = 32 * 1024  # runStream has a bounded partial-line buffer
COALESCE = 0.025
MAX_LATENCY = 0.1
HYPR_EVENTS = {
    'openwindow', 'closewindow', 'activewindow', 'activewindowv2', 'windowtitle',
    'windowtitlev2', 'movewindow', 'movewindowv2', 'workspace', 'workspacev2',
    'focusedmon', 'focusedmonv2', 'createworkspace', 'createworkspacev2',
    'destroyworkspace', 'destroyworkspacev2', 'moveworkspace', 'moveworkspacev2',
    'monitoradded', 'monitoraddedv2', 'monitorremoved', 'configreloaded',
    'urgent', 'pin', 'togglegroup', 'changegroupactive', 'activespecial',
    'activespecialv2', 'renameworkspace',
}


def text(value, limit=1024):
    if not isinstance(value, str):
        return ''
    return ' '.join(value.split())[:limit]


def identifier(value):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        return ''
    return str(value)


def address(value):
    if not isinstance(value, str):
        return ''
    value = value.lower().removeprefix('0x')
    return '0x' + value if re.fullmatch('[0-9a-f]{1,32}', value) else ''


def checked_array(value):
    if not isinstance(value, list) or len(value) > MAX_ITEMS:
        raise ValueError('invalid or oversized snapshot')
    return value


def window(wid, app, title, workspace, output, focused=False, minimized=False,
           minimizable=False, urgent=False, workspaces=None):
    app = app if isinstance(app, str) else ''
    if len(app) > 4096:
        raise ValueError('oversized application identity')
    return dict(id=wid, appId=app, title=text(title, 512),
                workspace=workspace, output=output, focused=bool(focused),
                minimized=bool(minimized), minimizable=bool(minimizable),
                urgent=bool(urgent), workspaces=workspaces or [workspace])


def hypr_workspace(value):
    """Legacy IDs and current public typed workspace addresses."""
    if not isinstance(value, dict):
        return ''
    if value.get('type') in ('named', 'normal') and 'id' not in value:
        name = identifier(value.get('address'))
        return 'name:' + name if name else ''
    if value.get('type') == 'special':
        return identifier(value.get('address'))
    if 'id' in value:
        return identifier(value['id'])
    return identifier(value.get('address'))


def normalize_hypr(clients, monitors, workspaces, active, urgent=()):
    clients, monitors, workspaces = map(checked_array, (clients, monitors, workspaces))
    outputs = {m.get('id'): text(m.get('name')) for m in monitors if isinstance(m, dict)}
    visible, focused_ws = set(), set()
    for m in monitors:
        if not isinstance(m, dict):
            continue
        for key in ('activeWorkspace', 'specialWorkspace'):
            ws = hypr_workspace(m.get(key))
            if ws and ws not in ('0', '-99'):
                visible.add(ws)
                if m.get('focused') is True:
                    focused_ws.add(ws)
    normalized_ws = []
    for index, ws in enumerate(workspaces):
        if not isinstance(ws, dict):
            continue
        wid = hypr_workspace(ws)
        if wid:
            normalized_ws.append(dict(id=wid, name=text(ws.get('name')), output=text(ws.get('monitor')),
                                      idx=index, active=wid in visible, focused=wid in focused_ws))
    active_id = address(active.get('address')) if isinstance(active, dict) else ''
    normalized, seen = [], set()
    for c in clients:
        if not isinstance(c, dict) or c.get('mapped', True) is False:
            continue
        wid = address(c.get('address'))
        if not wid or wid in seen:
            continue
        seen.add(wid)
        ws = hypr_workspace(c.get('workspace'))
        # hidden includes inactive grouped tabs: it is not a minimize capability.
        normalized.append(window(wid, c.get('class') or c.get('initialClass'), c.get('title'), ws,
                                 outputs.get(c.get('monitor'), ''), wid == active_id,
                                 urgent=wid != active_id and (c.get('urgent') is True or wid in urgent)))
    return dict(windows=normalized, workspaces=normalized_ws)


def normalize_mango(clients, monitors):
    clients, monitors = checked_array(clients), checked_array(monitors)
    workspaces, active, focused_ids = [], set(), set()
    for m in monitors:
        if not isinstance(m, dict):
            continue
        output = text(m.get('name'))
        active_client = m.get('active_client') or {}
        if m.get('active') is True and isinstance(active_client, dict):
            focused_ids.add(identifier(active_client.get('id')))
        for tag in checked_array(m.get('tags', [])):
            if not isinstance(tag, dict):
                continue
            tid = identifier(tag.get('index'))
            if not tid:
                continue
            wid = output + ':' + tid
            selected = tag.get('is_active') is True
            if selected:
                active.add(wid)
            workspaces.append(dict(id=wid, output=output, idx=tag['index'], name=tid,
                                   active=selected, focused=selected and m.get('active') is True))
    normalized, seen = [], set()
    for c in clients:
        if not isinstance(c, dict) or c.get('is_swallowedby') is True:
            continue
        wid = identifier(c.get('id'))
        if not re.fullmatch('[0-9]+', wid) or wid in seen:
            continue
        minimized = c.get('is_minimized') is True
        if not minimized and (c.get('is_scratchpad') is True or c.get('is_namedscratchpad') is True):
            continue
        seen.add(wid)
        output = text(c.get('monitor'))
        tags = checked_array(c.get('tags', []))
        memberships = [output + ':' + identifier(t) for t in tags if identifier(t)]
        primary = next((ws for ws in memberships if ws in active), next(iter(memberships), ''))
        normalized.append(window(wid, c.get('appid'), c.get('title'), primary, output,
                                 wid in focused_ids, minimized, not minimized,
                                 c.get('is_urgent') is True, memberships))
    return dict(windows=normalized, workspaces=workspaces)


def normalize_sway(tree, workspaces):
    normalized_ws = []
    for w in checked_array(workspaces):
        if isinstance(w, dict):
            normalized_ws.append(dict(id=identifier(w.get('id')), name=text(w.get('name')),
                                      idx=w.get('num', 0), output=text(w.get('output')),
                                      active=w.get('visible') is True, focused=w.get('focused') is True))
    windows = []
    # Iterative traversal bounds malformed/deep trees without recursion failures.
    pending = [(tree, '', '')]
    visited = 0
    while pending:
        node, output, workspace = pending.pop()
        visited += 1
        if visited > MAX_ITEMS * 8:
            raise ValueError('oversized tree')
        if not isinstance(node, dict):
            continue
        if node.get('type') == 'output':
            output = text(node.get('name'))
        if node.get('type') == 'workspace':
            workspace = identifier(node.get('id'))
        props = node.get('window_properties') or {}
        if not isinstance(props, dict):
            props = {}
        if output != '__i3' and (node.get('app_id') is not None or node.get('pid') is not None or node.get('window') is not None):
            wid = identifier(node.get('id'))
            if re.fullmatch('[0-9]+', wid):
                windows.append(window(wid, node.get('app_id') or props.get('class') or props.get('instance'),
                                      node.get('name'), workspace, output, node.get('focused') is True,
                                      urgent=node.get('urgent') is True))
        for child in checked_array(node.get('nodes', [])) + checked_array(node.get('floating_nodes', [])):
            pending.append((child, output, workspace))
    checked_array(windows)
    return dict(windows=windows, workspaces=normalized_ws)


def connect(path):
    if not path:
        raise OSError('missing compositor socket')
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(1)
        sock.connect(path)
        return sock
    except BaseException:
        sock.close()
        raise


def query(path, command, newline=False):
    with connect(path) as sock:
        sock.sendall(command.encode() + (b'\n' if newline else b''))
        data = bytearray()
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_BYTES:
                raise ValueError('oversized reply')
            if newline and b'\n' in data:
                break
        return json.loads(data.split(b'\n', 1)[0] if newline else data)


def recv_exact(sock, size):
    if size > MAX_BYTES:
        raise ValueError('oversized IPC frame')
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size-len(data))
        if not chunk:
            raise EOFError('IPC connection closed')
        data.extend(chunk)
    return bytes(data)


def i3_frame(kind, payload):
    return b'i3-ipc' + struct.pack('<II', len(payload), kind) + payload


def i3_query(path, kind, payload=b''):
    with connect(path) as sock:
        sock.sendall(i3_frame(kind, payload))
        header = recv_exact(sock, 14)
        if header[:6] != b'i3-ipc':
            raise ValueError('invalid IPC header')
        length, reply_kind = struct.unpack('<II', header[6:])
        if reply_kind != kind:
            raise ValueError('unexpected IPC reply')
        return json.loads(recv_exact(sock, length))


class Publisher:
    def __init__(self, write=None):
        self.write = write or (lambda value: print(json.dumps(value, ensure_ascii=True, separators=(',', ':')), flush=True))
        self.previous = None
        self.serial = 0

    def reset(self):
        self.previous = None
        self.write(dict(event='reset'))

    def snapshot(self, data):
        # Only fields used by the UI survive normalization. Geometry never crosses
        # into Luau, and repeated equivalent snapshots produce no renderer work.
        data['windows'].sort(key=lambda w: w['id'])
        data['workspaces'].sort(key=lambda w: (w.get('output', ''), w.get('idx', 0), w['id']))
        encoded = json.dumps(data, ensure_ascii=True, separators=(',', ':'))
        if len(encoded) > MAX_BYTES:
            raise ValueError('oversized normalized snapshot')
        if encoded == self.previous:
            return
        self.previous = encoded
        self.serial += 1
        # Chunk snapshots to stay safely below runStream's 64-KiB partial-line
        # buffer; the Luau transport publishes only after the complete last part.
        part = dict(token=self.serial, index=1, windows=[], workspaces=[], last=False)
        size = 256
        for family in ('workspaces', 'windows'):
            for item in data[family]:
                item_size = len(json.dumps(item, ensure_ascii=True)) + 2
                if item_size > FRAME_BYTES - 256:
                    raise ValueError('oversized snapshot item')
                if size + item_size > FRAME_BYTES:
                    self.write(dict(event='snapshot-part', data=part))
                    part = dict(token=self.serial, index=part['index']+1, windows=[], workspaces=[], last=False)
                    size = 256
                part[family].append(item)
                size += item_size
        part['last'] = True
        self.write(dict(event='snapshot-part', data=part))


class Bridge:
    def __init__(self, kind, environment=None, publisher=None):
        self.kind = kind
        self.env = os.environ if environment is None else environment
        self.publisher = publisher or Publisher()
        self.urgent = set()
        self.caches = {}

    def paths(self):
        if self.kind == 'mango':
            return self.env.get('MANGO_INSTANCE_SIGNATURE', ''), None
        if self.kind == 'sway':
            return self.env.get('SWAYSOCK', ''), None
        signature = self.env.get('HYPRLAND_INSTANCE_SIGNATURE', '')
        if not signature or '/' in signature or '\x00' in signature:
            raise ValueError('invalid Hyprland instance signature')
        runtime = self.env.get('XDG_RUNTIME_DIR', '')
        directory = Path(runtime)/'hypr'/signature if runtime else Path('/tmp/hypr')/signature
        if not directory.is_dir():
            directory = Path('/tmp/hypr')/signature
        return str(directory/'.socket.sock'), str(directory/'.socket2.sock')

    def initial_snapshot(self, path):
        if self.kind == 'hyprland':
            return normalize_hypr(query(path, 'j/clients'), query(path, 'j/monitors'),
                                  query(path, 'j/workspaces'), query(path, 'j/activewindow'), self.urgent)
        if self.kind == 'sway':
            return normalize_sway(i3_query(path, 4), i3_query(path, 1))
        if 'clients' not in self.caches or 'monitors' not in self.caches:
            return None
        return normalize_mango(self.caches['clients'], self.caches['monitors'])

    def session(self):
        path, event_path = self.paths()
        with selectors.DefaultSelector() as selector:
            sockets = []
            buffers = {}
            self.caches = {}
            self.urgent = set()
            try:
                commands = ('watch all-monitors', 'watch all-clients') if self.kind == 'mango' else (None,)
                for command in commands:
                    sock = connect(event_path or path)
                    sockets.append(sock)
                    if command:
                        sock.sendall((command+'\n').encode())
                    elif self.kind == 'sway':
                        sock.sendall(i3_frame(2, b'["window","workspace","output","shutdown"]'))
                        header = recv_exact(sock, 14)
                        if header[:6] != b'i3-ipc' or struct.unpack('<I', header[10:])[0] != 2:
                            raise ValueError('invalid subscription reply')
                        reply = json.loads(recv_exact(sock, struct.unpack('<I', header[6:10])[0]))
                        if reply.get('success') is not True:
                            raise ValueError('subscription rejected')
                    sock.setblocking(False)
                    selector.register(sock, selectors.EVENT_READ)
                    buffers[sock] = bytearray()
                # Subscribe before querying; events arriving during queries stay
                # queued and trigger the next coalesced snapshot, closing the race.
                data = self.initial_snapshot(path)
                if data is not None:
                    self.publisher.snapshot(data)
                deadline = first_change = None
                while True:
                    timeout = None if deadline is None else max(0, deadline-time.monotonic())
                    ready = selector.select(timeout)
                    for key, _ in ready:
                        sock = key.fileobj
                        # Bound each drain for fairness under sustained event load.
                        for _ in range(32):
                            try:
                                chunk = sock.recv(65536)
                            except BlockingIOError:
                                break
                            if not chunk:
                                raise EOFError('event connection closed')
                            buffer = buffers[sock]
                            buffer.extend(chunk)
                            if len(buffer) > MAX_BYTES:
                                raise ValueError('oversized event')
                            changed = False
                            if self.kind == 'sway':
                                while len(buffer) >= 14:
                                    if buffer[:6] != b'i3-ipc':
                                        raise ValueError('invalid IPC header')
                                    length, kind = struct.unpack('<II', buffer[6:14])
                                    if length > MAX_BYTES:
                                        raise ValueError('oversized event')
                                    if len(buffer) < length+14:
                                        break
                                    payload = json.loads(buffer[14:14+length])
                                    del buffer[:14+length]
                                    if kind == 0x80000006:
                                        raise EOFError('compositor shutdown')
                                    changed = True
                            else:
                                while b'\n' in buffer:
                                    line, _, remainder = buffer.partition(b'\n')
                                    buffer[:] = remainder
                                    if self.kind == 'hyprland':
                                        event, _, payload = line.decode('utf-8', errors='replace').partition('>>')
                                        if event == 'urgent':
                                            wid = address(payload)
                                            if wid:
                                                self.urgent.add(wid)
                                        changed = event in HYPR_EVENTS or changed
                                    else:
                                        message = json.loads(line)
                                        if not isinstance(message, dict) or 'error' in message:
                                            raise ValueError('watch subscription rejected')
                                        for family in ('clients', 'monitors'):
                                            if family in message:
                                                self.caches[family] = checked_array(message[family])
                                                changed = True
                            if changed:
                                now = time.monotonic()
                                first_change = first_change if first_change is not None else now
                                deadline = min(now+COALESCE, first_change+MAX_LATENCY)
                    if deadline is not None and time.monotonic() >= deadline:
                        data = self.initial_snapshot(path)
                        if data is not None:
                            self.publisher.snapshot(data)
                            if self.kind == 'hyprland':
                                self.urgent.intersection_update(w['id'] for w in data['windows'] if w['urgent'])
                        deadline = first_change = None
            finally:
                for sock in sockets:
                    sock.close()

    def run(self):
        delay = 1
        while True:
            self.publisher.reset()
            started = time.monotonic()
            try:
                self.session()
            except BrokenPipeError:
                return
            except (OSError, EOFError, ValueError, KeyError, TypeError, RecursionError):
                # No payload/title/path logging. A reset immediately removes stale
                # windows, then a bounded backoff prevents reconnect spin.
                self.publisher.reset()
                self.publisher.write(dict(event='error', data='Local compositor IPC unavailable; retrying.'))
                if time.monotonic()-started > 10:
                    delay = 1
                time.sleep(delay)
                delay = min(30, delay*2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compositor', choices=('hyprland', 'mango', 'sway'))
    args = parser.parse_args()
    try:
        Bridge(args.compositor).run()
    except (BrokenPipeError, KeyboardInterrupt):
        return


if __name__ == '__main__':
    main()
