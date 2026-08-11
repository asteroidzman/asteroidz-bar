pragma Singleton

// Where this machine is.
//
// One place that answers it, because more than one thing needs it now: the
// weather module has always wanted a latitude, and a `solar` dynamic wallpaper
// -- whose schedule is keyed by the sun's altitude rather than the clock --
// cannot be evaluated without one. Two resolvers would mean two IP lookups per
// session and two chances to disagree about where you are.
//
// It is also handed to PLUGINS, as a `location` event, so a plugin that wants
// sunrise, a tide table or a local forecast does not have to geolocate for
// itself. That is the whole reason this is a shell singleton rather than a
// property on the weather pill.
//
// ── how it is resolved ──────────────────────────────────────────────────────
//
// A configured city if there is one (`bar { weather-location "..." }`), because
// a stated answer beats a guessed one. Otherwise by IP, which is wrong by a few
// miles and right about which country you are in -- fine for a temperature, and
// fine for the sun, whose altitude changes by well under a degree over that.
//
// Cached to disk, so a cold start does not wait on the network to know where it
// is. A location that is a day old is still correct; the file is refreshed in
// the background once the answer comes back.

import Quickshell
import Quickshell.Io
import QtQuick

Singleton {
    id: root

    property real lat: 0
    property real lon: 0
    // "Berlin, Germany" -- for anything that wants to say where the reading is
    // from. A temperature with no place attached is half an answer.
    property string place: ""
    // Nothing has answered yet. Callers must check this rather than testing
    // `lat === 0`: zero is a real latitude, and the Atlantic is not where
    // anybody lives but a bug that pretends it is would be invisible.
    readonly property bool known: resolved

    property bool resolved: false

    readonly property string cachePath:
        (Quickshell.env("XDG_CACHE_HOME")
         || (Quickshell.env("HOME") + "/.cache"))
        + "/asteroidz-bar/location.json"

    signal changed()

    function apply(la, lo, name, fromCache) {
        if (la === undefined || lo === undefined)
            return;
        lat = la;
        lon = lo;
        place = name || "";
        resolved = true;
        if (!fromCache)
            cache.setText(JSON.stringify({ lat: la, lon: lo, place: place }));
        changed();
    }

    FileView {
        id: cache
        path: root.cachePath
        atomicWrites: true
        preload: true
        onLoaded: {
            // Only as a head start. The lookup below runs regardless and
            // overwrites this -- a cached location is stale by definition, and
            // the one thing worse than not knowing where you are is being sure
            // of somewhere you left.
            if (root.resolved)
                return;
            try {
                const d = JSON.parse(text());
                root.apply(d.lat, d.lon, d.place, true);
            } catch (e) {
                // No cache, or a corrupt one. The lookup answers.
            }
        }
        onLoadFailed: {} // the ordinary first-run case
    }

    function fetch(url, ok) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200)
                return;
            try {
                ok(JSON.parse(xhr.responseText));
            } catch (e) {
                // A bad body is a bad body. Whatever was cached still stands.
            }
        };
        xhr.open("GET", url);
        xhr.send();
    }

    function locate() {
        if (Cfg.weatherLocation !== "") {
            fetch("https://geocoding-api.open-meteo.com/v1/search?name="
                  + encodeURIComponent(Cfg.weatherLocation) + "&count=1",
                  data => {
                      if (!data.results || !data.results.length)
                          return;
                      const r = data.results[0];
                      root.apply(r.latitude, r.longitude,
                                 r.name + (r.country ? ", " + r.country : ""));
                  });
            return;
        }
        fetch("http://ip-api.com/json/?fields=lat,lon,city,country", data => {
            if (data.lat === undefined)
                return;
            root.apply(data.lat, data.lon,
                       data.city
                       ? data.city + (data.country ? ", " + data.country : "")
                       : "");
        });
    }

    Component.onCompleted: locate()

    // A configured city changing is a different place, not a refresh.
    Connections {
        target: Cfg
        function onWeatherLocationChanged() { root.locate(); }
    }
}
