// ringserv.js — the browser half of the unified model.
//
// Served by the binary at /ringserv.js, so a page needs no build step and
// no package:
//
//     <script src="/ringserv.js"></script>
//     serv.call("orders.place", { client: "Ada" }).then(...)
//     serv.subscribe("menu", () => refresh())
//
// The same `service.action(payload)` call a Ring or JS service makes on
// the server, and the same call a RingScript page makes — one seam, three
// places.
(function (g) {
    "use strict";

    var API = "/api/v1";

    function call(target, payload) {
        var s = String(target);
        var dot = s.indexOf(".");
        if (dot < 1 || dot === s.length - 1) {
            return Promise.reject(new TypeError(
                'serv.call expects "service.action", got: ' + s));
        }
        return fetch(API, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                service: s.slice(0, dot),
                action: s.slice(dot + 1),
                payload: payload || {},
            }),
        }).then(function (r) { return r.json(); });
    }

    // Be told when a shape changes, instead of asking.
    //
    // THE HANDLER RECEIVES AN OFFSET, NOT DATA — deliberately, and it is
    // the whole design: you fetch through the ordinary call path you
    // already use, so paging, must-refetch and placement keep working and
    // there is never a second source of truth.
    //
    // A DROPPED EVENT COSTS LATENCY, NEVER CORRECTNESS. The browser
    // reconnects by itself with Last-Event-ID, and the optional poll below
    // converges even if every event is lost — so a page written against
    // this is correct on a network that eats server-sent events entirely.
    function subscribe(shape, onChange, options) {
        var opts = options || {};
        var pollMs = opts.poll === undefined ? 15000 : opts.poll;
        var seen = -1;
        var stopped = false;
        var es = null;
        var timer = null;

        function fire(offset) {
            if (offset === seen) return;
            seen = offset;
            try { onChange(offset, shape); } catch (e) { /* a page's bug is not ours */ }
        }

        // GIVING UP IS PART OF THE DESIGN, not an omission.
        //
        // EventSource retries by itself, forever, and that is right when a
        // server CAN stream and is merely down. It is wrong when the server
        // will never stream to this page at all, because then the tab holds
        // a dead connection open for as long as it lives and the page is no
        // better off for it.
        //
        // AND THE FAILURE THAT MATTERS DOES NOT RAISE AN ERROR. Measured in
        // a browser against this server on Windows, where it cannot stream:
        // the connection was not refused and no error fired — it simply sat
        // there, open and silent, and `onerror` never ran, so an
        // error-handler-based retreat would have waited forever. A proxy
        // that buffers produces exactly the same silence, which is why this
        // is not a Windows workaround.
        //
        // So the defence is a DEADLINE, not an error handler: a stream that
        // has not said `open` within a few seconds counts as a failed
        // attempt, whether or not anyone reported a failure. Three such
        // attempts and the stream is abandoned for the poll below. A stream
        // that HAS worked keeps the browser's own retry, which is the thing
        // it is genuinely good at.
        var OPEN_DEADLINE_MS = 6000;
        var everOpened = false;
        var attempts = 0;
        var deadline = null;

        function failed() {
            if (everOpened || stopped) return;
            if (deadline) { clearTimeout(deadline); deadline = null; }
            if (es) { es.close(); es = null; }
            if (attempts < 3) { setTimeout(open, 1000 * attempts); return; }
            // Decided: this server does not stream to us. Say it once, at
            // info level rather than as an error, because the page is about
            // to keep working — and poll faster to make up for it.
            if (pollMs > 3000) pollMs = 3000;
            if (typeof console !== "undefined" && console.info) {
                console.info("ringserv: no live stream for shape '" + shape +
                    "' after 3 attempts — falling back to polling every " +
                    (pollMs / 1000) + "s. The page stays correct, just slower.");
            }
        }

        function open() {
            if (stopped) return;
            attempts++;
            es = new EventSource("/sync/stream?shape=" + encodeURIComponent(shape));
            deadline = setTimeout(failed, OPEN_DEADLINE_MS);
            es.addEventListener("open", function (ev) {
                everOpened = true;
                if (deadline) { clearTimeout(deadline); deadline = null; }
                try { fire(JSON.parse(ev.data).offset); } catch (e) {}
            });
            es.addEventListener("advanced", function (ev) {
                everOpened = true;
                try { fire(JSON.parse(ev.data).offset); } catch (e) {}
            });
            // `bye` is this server closing a bounded stream on purpose;
            // EventSource reconnects on its own, so nothing is needed here.
            es.onerror = function () {
                // A reported error and a silent hang are the same event to
                // us: one attempt that produced nothing. Once a stream HAS
                // worked, the browser's own retry is left alone — that is
                // the thing it is genuinely good at.
                if (!everOpened) failed();
            };
        }

        // The safety net, and it is why this is honest rather than hopeful:
        // a proxy that buffers, a browser that suspends a background tab,
        // or a server with no streaming at all still converges here.
        function poll() {
            if (stopped || !pollMs) return;
            timer = setTimeout(function () {
                fetch("/sync/shape?shape=" + encodeURIComponent(shape) + "&offset=0&limit=1")
                    .then(function (r) { return r.json(); })
                    .then(function (j) { if (j && j.data) fire(j.data.offset); })
                    .catch(function () {})
                    .then(poll);
            }, pollMs);
        }

        open();
        poll();

        return function stop() {
            stopped = true;
            if (es) es.close();
            if (timer) clearTimeout(timer);
            if (deadline) clearTimeout(deadline);
        };
    }

    g.serv = g.serv || {};
    g.serv.call = call;
    g.serv.subscribe = subscribe;
})(window);
