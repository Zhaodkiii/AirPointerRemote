// Viewport coordinates are CSS pixels; the framebuffer and pointer protocol
// remain in remote pixels. Centers are normalized so rotation retains context.
export class DesktopViewport {
    layout = 'fit';
    zoom = 1;
    centerX = 0.5;
    centerY = 0.5;

    reset(layout = this.layout) {
        this.layout = layout;
        this.zoom = 1;
        this.centerX = 0.5;
        this.centerY = 0.5;
    }

    frame(width, height, remoteWidth, remoteHeight) {
        const fit = Math.min(width / remoteWidth, height / remoteHeight);
        const fill = Math.max(width / remoteWidth, height / remoteHeight);
        const base = this.layout === 'fill' ? fill : this.layout === 'actual' ? 1 : fit;
        const scale = base * this.zoom;
        const left = this.offset(width, scale * remoteWidth, this.centerX);
        const top = this.offset(height, scale * remoteHeight, this.centerY);
        return {fit, base, scale, left, top};
    }

    offset(view, content, center) {
        if (content <= view) return (view - content) / 2;
        return Math.min(0, Math.max(view - content, view / 2 - center * content));
    }

    gesture(width, height, remoteWidth, remoteHeight, previous, point, ratio) {
        const before = this.frame(width, height, remoteWidth, remoteHeight);
        const min = Math.min(1, before.fit / before.base);
        const max = Math.max(1, 2 / before.base, 4 * before.fit / before.base);
        this.zoom = Math.min(max, Math.max(min, this.zoom * ratio));
        const scale = before.base * this.zoom;
        const anchorX = (previous.x - before.left) / before.scale;
        const anchorY = (previous.y - before.top) / before.scale;
        this.centerX = this.center(width, remoteWidth * scale, point.x - anchorX * scale);
        this.centerY = this.center(height, remoteHeight * scale, point.y - anchorY * scale);
    }

    center(view, content, offset) {
        if (content <= view) return 0.5;
        const clamped = Math.min(0, Math.max(view - content, offset));
        return (view / 2 - clamped) / content;
    }
}
