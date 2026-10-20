// The page side of HostScreenSession (A3 spec §4). Swift calls window.minisScreen; the page reports
// RFB events through the `minisScreen` message handler.
import RFB from "./novnc-rfb.js";

const post = (message) => window.webkit.messageHandlers.minisScreen.postMessage(message);
let rfb = null;

function requireConnected() {
    if (rfb === null) {
        throw new Error("not connected");
    }
    return rfb;
}

window.minisScreen = {
    connect(url, quality, compression) {
        if (rfb !== null) {
            rfb.disconnect();
        }
        // shared: the person at the host keeps their own session while the phone watches.
        rfb = new RFB(document.getElementById("screen"), url, { wsProtocols: ["binary"], shared: true });
        rfb.viewOnly = true;
        rfb.scaleViewport = true;
        rfb.resizeSession = false;
        rfb.qualityLevel = quality;
        rfb.compressionLevel = compression;
        rfb.addEventListener("connect", () => post({ type: "connect" }));
        rfb.addEventListener("disconnect", (e) => { rfb = null; post({ type: "disconnect", clean: e.detail.clean }); });
        rfb.addEventListener("credentialsrequired", (e) => post({ type: "credentialsrequired", types: e.detail.types }));
        rfb.addEventListener("securityfailure", (e) =>
            post({ type: "securityfailure", status: e.detail.status, reason: e.detail.reason ?? "" }));
    },

    sendCredentials(username, password) {
        requireConnected().sendCredentials(username === null ? { password } : { username, password });
    },

    setViewOnly(viewOnly) {
        requireConnected().viewOnly = viewOnly;
    },

    disconnect() {
        if (rfb !== null) {
            rfb.disconnect();
        }
    },

    // Returns base64 JPEG of the framebuffer scaled to width×height (the size ScreenScale chose).
    async capture(width, height, quality) {
        const frame = requireConnected().getImageData();
        const bitmap = await createImageBitmap(frame);
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        canvas.getContext("2d").drawImage(bitmap, 0, 0, width, height);
        const url = canvas.toDataURL("image/jpeg", quality);
        return { frameWidth: frame.width, frameHeight: frame.height, jpeg: url.slice(url.indexOf(",") + 1) };
    },

    framebufferSize() {
        const frame = requireConnected().getImageData();
        return { width: frame.width, height: frame.height };
    },

    // The agent's events are already in framebuffer pixels, so they go to RFB.messages directly instead of
    // through noVNC's input handlers, which map from page coordinates and honour viewOnly. This reaches
    // noVNC 1.7.0's private socket; the bundle is pinned, so a version bump has to recheck it.
    input(events) {
        const sock = requireConnected()._sock;
        for (const event of events) {
            if (event.kind === "pointer") {
                RFB.messages.pointerEvent(sock, event.x, event.y, event.mask);
            } else {
                RFB.messages.keyEvent(sock, event.keysym, event.down ? 1 : 0);
            }
        }
    },
};

post({ type: "ready" });
