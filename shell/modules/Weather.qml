// Current conditions: one glyph and a temperature.
//
// open-meteo, the same source and the same WMO-to-artwork mapping the waybar
// plugin used, so the pill is indistinguishable from the one it replaces. No
// API key, no account, and it answers in a single request.
//
// XMLHttpRequest rather than a curl subprocess: this is a client now, so a
// slow DNS lookup costs only this pill's next refresh instead of a frame.

import Quickshell
import QtQuick
import ".."

Pill {
    id: root

    property int code: 3
    property bool isDay: true
    property int tempC: 0
    property bool valid: false
    property real lat: 0
    property real lon: 0

    readonly property var wmoIcons: ({
        0: "sunny", 1: "sunny", 2: "pcloudy", 3: "cloud",
        45: "fog", 48: "fog",
        51: "rain", 53: "rain", 55: "rain", 56: "rain", 57: "rain",
        61: "rain", 63: "rain", 66: "rain", 80: "rain", 81: "rain",
        65: "pour", 67: "pour", 82: "pour",
        71: "snow", 73: "snow", 77: "snow", 85: "snow",
        75: "heavy-snow", 86: "heavy-snow",
        95: "tstorm", 96: "tstorm", 99: "tstorm"
    })

    function art() {
        let name = wmoIcons[code] || "cloud";
        // Only the clear and partly-cloudy glyphs have a night variant; rain
        // at night is still rain.
        if (!isDay && (name === "sunny" || name === "pcloudy"))
            name = name === "sunny" ? "night" : "npcloudy";
        return "waybar-weather/" + name + ".svg";
    }

    icons: [art()]
    text: valid ? tempC + "°" : "--°"

    // Pinned to the widest reading the pill can ever show, so a temperature
    // crossing zero or going double-digit does not shove the section.
    //
    // widthForText, which keeps the icon's advance: pinning to the label
    // alone left this pill ~28px narrow, so the temperature overflowed its
    // box and sat 3px from the idle glyph beside it.
    fixedWidth: widthForText(widest.width)
    TextMetrics { id: widest; font: root.textFont; text: "-99°" }

    function fetch(url, ok) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200)
                return;
            try {
                ok(JSON.parse(xhr.responseText));
            } catch (e) {
                // A bad body is a bad body; the next tick tries again.
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
                      root.lat = data.results[0].latitude;
                      root.lon = data.results[0].longitude;
                      root.refresh();
                  });
            return;
        }
        // No city configured: geolocate by IP, the same fallback the plugin
        // used. Wrong by a few miles never mattered for a temperature.
        fetch("http://ip-api.com/json/?fields=lat,lon", data => {
            if (data.lat === undefined)
                return;
            root.lat = data.lat;
            root.lon = data.lon;
            root.refresh();
        });
    }

    function refresh() {
        if (lat === 0 && lon === 0)
            return;
        fetch("https://api.open-meteo.com/v1/forecast?latitude=" + lat.toFixed(4)
              + "&longitude=" + lon.toFixed(4)
              + "&current=temperature_2m,is_day,weather_code&timezone=auto",
              data => {
                  if (!data.current)
                      return;
                  root.tempC = Math.round(data.current.temperature_2m);
                  root.code = data.current.weather_code;
                  root.isDay = data.current.is_day === 1;
                  root.valid = true;
              });
    }

    Component.onCompleted: locate()

    Timer {
        interval: Math.max(1, Cfg.weatherInterval) * 60 * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
