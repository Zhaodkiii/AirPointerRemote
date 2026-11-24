import RFB from '@novnc/novnc';
import { DesktopViewport } from './viewport.mjs';

const post = (kind, value = '') => webkit.messageHandlers.desktop.postMessage({kind, value});
const channel = {
    binaryType: 'arraybuffer', protocol: '', readyState: 'open',
    onmessage: null, onopen: null, onerror: null, onclose: null,
    send(bytes) {
        let text = '';
        for (const byte of new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength)) {
            text += String.fromCharCode(byte);
        }
        post('send', btoa(text));
    },
    close() { this.readyState = 'closed'; post('close'); }
};
let session;
const viewport = new DesktopViewport();
let overviewAvailable = false;
let wheelAnchor;
let x = 0, y = 0;
let padButtons = 0;
let leftPress;
const clickPosition = () => [x / session._fbWidth, y / session._fbHeight];
window.padInput = (action, a, b) => {
    if (!session || session.viewOnly) return;
    window.endScroll();
    let clicked = action === 'pulse' && a === 1 && !padButtons;
    if (action === 'press' && a === 1) leftPress = {x, y};
    if (action === 'release' && a === 1) {
        clicked = !!leftPress && padButtons === 1;
        leftPress = undefined;
    }
    if (action === 'move') {
        const gain = 1 / Math.max(0.3, session._display.scale);
        x += a * gain;
        y += b * gain;
        if (leftPress && Math.hypot(x - leftPress.x, y - leftPress.y) > 3) leftPress = undefined;
    } else if (action === 'press') padButtons |= a;
    else if (action === 'release') padButtons &= ~a;
    else if (action === 'pulse') pointer(padButtons | a);
    pointer(padButtons);
    const rect = session._canvas.getBoundingClientRect();
    session._cursor.move(rect.left + x * session._display.scale, rect.top + y * session._display.scale);
    if (clicked) return clickPosition();
};
const main = document.querySelector('main');

function pointer(buttons) {
    if (session.viewOnly || session._rfbConnectionState !== 'connected') return;
    x = Math.max(0, Math.min(session._fbWidth - 1, x));
    y = Math.max(0, Math.min(session._fbHeight - 1, y));
    RFB.messages.pointerEvent(session._sock, Math.round(x), Math.round(y), buttons);
    session._sock.flush();
}
let directDown = false;
window.endScroll = () => {
    if ((directDown || wheelAnchor?.sent) && !padButtons) pointer(0);
    directDown = false;
    wheelAnchor = undefined;
};
function desktopPoint(u, v, clamp = false) {
    const rect = session._canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    const px = u * main.clientWidth - rect.left, py = v * main.clientHeight - rect.top;
    if (!clamp && (px < 0 || py < 0 || px >= rect.width || py >= rect.height)) return;
    return {
        x: session._display.absX(Math.max(0, Math.min(rect.width - 1, px))),
        y: session._display.absY(Math.max(0, Math.min(rect.height - 1, py)))
    };
}
window.directTouch = (action, u, v) => {
    if (!session || session.viewOnly || padButtons || session._rfbConnectionState !== 'connected') return;
    if (action === 'move' && !directDown) return;
    const point = desktopPoint(u, v, directDown);
    if (!point) return;
    x = point.x;
    y = point.y;
    directDown = action === 'down' || action === 'move';
    pointer(action === 'right' ? 4 : 1);
    if (!directDown) pointer(0);
    const rect = session._canvas.getBoundingClientRect();
    session._cursor.move(rect.left + x * session._display.scale, rect.top + y * session._display.scale);
    if (action === 'click') return clickPosition();
};
window.startScroll = (u, v) => {
    window.endScroll();
    if (!session || session.viewOnly || padButtons) return;
    const point = desktopPoint(u, v);
    if (point) wheelAnchor = point;
};
window.scrollTicks = (dx, dy, atPointer) => {
    if (!session || session.viewOnly || session._rfbConnectionState !== 'connected') return;
    const anchor = atPointer ? {x: Math.round(x), y: Math.round(y)} : wheelAnchor;
    if (!anchor || (!atPointer && padButtons)) return;
    const bytes = [];
    function encode(ticks, positive, negative) {
        for (let i = 0; i < Math.abs(ticks); i++) {
            for (const mask of [ticks > 0 ? positive : negative, 0]) {
                bytes.push(5, mask | padButtons, anchor.x >> 8, anchor.x & 255, anchor.y >> 8, anchor.y & 255);
            }
        }
    }
    encode(dy, 8, 16);
    encode(dx, 32, 64);
    if (bytes.length) {
        channel.send(Uint8Array.from(bytes));
        if (!atPointer) anchor.sent = true;
    }
};
window.adjustViewport = (u, v, nextU, nextV, ratio) => {
    const point = (x, y) => ({x: x * main.clientWidth, y: y * main.clientHeight});
    session.moveViewport(point(u, v), point(nextU, nextV), ratio);
};
// Publish from completed VNC paints. A trailing update preserves the last frame of a burst.
function prepareMirrorVideo(canvas) {
    const surface = document.createElement('canvas');
    const ctx = surface.getContext('2d', {alpha: false});
    let last = -Infinity;
    let timer;
    function publish() {
        timer = undefined;
        if (!canvas.width || !canvas.height || channel.readyState !== 'open') return;
        const scale = Math.min(1, 720 / Math.max(canvas.width, canvas.height));
        const width = Math.max(2, Math.round(canvas.width * scale / 2) * 2);
        const height = Math.max(2, Math.round(canvas.height * scale / 2) * 2);
        if (surface.width !== width || surface.height !== height) {
            surface.width = width;
            surface.height = height;
        }
        ctx.drawImage(canvas, 0, 0, width, height);
        post('mirrorFrame', surface.toDataURL('image/jpeg', 0.78).split(',')[1]);
        last = performance.now();
    }
    const display = session._display;
    const flip = display.flip.bind(display);
    display.flip = (...args) => {
        flip(...args);
        if (display.pending() && !args[0]) return;
        const delay = 100 - (performance.now() - last);
        if (delay <= 0) {
            clearTimeout(timer);
            publish();
        } else if (timer === undefined) {
            timer = setTimeout(publish, delay);
        }
    };
    publish();
}
window.begin = (username, password, method) => {
    const expected = method === 'account' ? 30 : 2;
    // Pin the selected credential type, including RFB 3.3 server-selected authentication.
    class MacSession extends RFB {
        _isSupportedSecurityType(type) { return type === expected; }
        _negotiateAuthentication() {
            if (this._rfbAuthScheme !== expected) return this._fail('Authentication method unavailable');
            return super._negotiateAuthentication();
        }
        _screenSize() {
            const size = super._screenSize();
            if (!this.resizeSession) return size;
            const factor = Math.min(2, 1920 / Math.max(1, size.w, size.h));
            return {w: Math.max(2, 2 * Math.round(size.w * factor / 2)),
                    h: Math.max(2, 2 * Math.round(size.h * factor / 2))};
        }
        _updateScale() {
            const width = main.clientWidth, height = main.clientHeight;
            if (!width || !height || !this._fbWidth || !this._fbHeight) return;
            const frame = viewport.frame(width, height, this._fbWidth, this._fbHeight);
            this._display.scale = frame.scale;
            const canReset = viewport.layout !== 'fit' || Math.abs(viewport.zoom - 1) > 0.005;
            if (canReset !== overviewAvailable) {
                overviewAvailable = canReset;
                post('overview', canReset ? 'yes' : 'no');
            }
            Object.assign(this._canvas.style, {
                position: 'absolute',
                margin: '0',
                left: frame.left + 'px',
                top: frame.top + 'px'
            });

        }
        moveViewport(previous, point, ratio) {
            if (!main.clientWidth || !main.clientHeight || !this._fbWidth || !this._fbHeight) return;
            const rect = main.getBoundingClientRect();
            const local = point => ({x: point.x - rect.left, y: point.y - rect.top});
            viewport.gesture(main.clientWidth, main.clientHeight, this._fbWidth, this._fbHeight,
                local(previous), local(point), ratio);
            this._updateScale();
        }
        _sendMouse(localX, localY, buttons) {
            x = this._display.absX(localX);
            y = this._display.absY(localY);
            super._sendMouse(localX, localY, buttons | padButtons);
        }
        _resize(width, height) {
            super._resize(width, height);
            x = Math.floor(width / 2);
            y = Math.floor(height / 2);
            post('resolution', width + ' × ' + height);
        }
    }
    session = new MacSession(main, channel, {credentials: {username, password}});
    session.background = '#07090d';
    session._screen.style.position = 'relative';
    session._screen.style.overflow = 'hidden';
    session.scaleViewport = true;
    session.addEventListener('connect', () => {
        post('connected');
        try { prepareMirrorVideo(session._canvas); } catch { post('mirrorPiP', 'unavailable'); }
    });
    session.addEventListener('securityfailure', () => post('authError'));
    session.addEventListener('disconnect', () => post('ended'));
};
window.receive = encoded => channel.onmessage({data: Uint8Array.from(atob(encoded), c => c.charCodeAt(0)).buffer});
window.typeText = text => {
    for (const ch of text) {
        const code = ch.codePointAt(0);
        session.sendKey(code === 10 ? 0xff0d : code <= 255 ? code : 0x01000000 + code);
    }
};
window.specialKey = (code, modifiers) => {
    for (const modifier of modifiers) session.sendKey(modifier, undefined, true);
    session.sendKey(code);
    for (const modifier of modifiers.slice().reverse()) session.sendKey(modifier, undefined, false);
};
window.configure = (scale, observing, quality, adaptive = false) => {
    if (observing && padButtons) { padButtons = 0; pointer(0); }
    window.endScroll();
    if (viewport.layout !== scale) viewport.reset(scale);
    session.viewOnly = observing;
    session.resizeSession = adaptive;
    session.qualityLevel = quality;
    session.compressionLevel = quality === 3 ? 7 : 2;
    session._updateScale();
};
window.resetViewport = () => {
    viewport.reset('fit');
    session._updateScale();
};
window.sendClipboard = text => session.clipboardPasteFrom(text);
window.screenshot = () => session._display.toDataURL('image/jpeg', 0.9);
post('ready');
