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
    property var bar: null
    // Where the reading is from, for the popover: a temperature with no place
    // attached is only half an answer, and the IP fallback can be wrong.
    property string place: ""
    // [{ day, code, hi, lo }] -- today first.
    property var forecast: []

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

    // WMO codes in words, for the popover. The pill shows artwork; a list of
    // days needs something readable beside each one.
    readonly property var wmoText: ({
        0: "Clear", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
        45: "Fog", 48: "Rime fog",
        51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle",
        56: "Freezing drizzle", 57: "Freezing drizzle",
        61: "Light rain", 63: "Rain", 65: "Heavy rain",
        66: "Freezing rain", 67: "Freezing rain",
        71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
        80: "Showers", 81: "Showers", 82: "Violent showers",
        85: "Snow showers", 86: "Snow showers",
        95: "Thunderstorm", 96: "Thunderstorm, hail", 99: "Thunderstorm, hail"
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

    // The pill said the temperature and nothing else, and clicking it did
    // nothing at all -- which for a pill that is visibly a button is worse
    // than not being one.
    onClicked: button => {
        if (button !== Qt.LeftButton || !bar)
            return;
        if (!valid) {
            bar.showMenu(root, [
                { text: "No reading yet", enabled: false }
            ]);
            return;
        }

        const rows = [
            { text: (wmoText[code] || "Unknown") + "  ·  " + tempC + "°C",
              icon: art(), enabled: false }
        ];
        if (place !== "")
            rows.push({ text: place, enabled: false });
        if (forecast.length > 0) {
            rows.push({ separator: true });
            for (const d of forecast) {
                rows.push({
                    text: d.day + "   " + d.hi + "°  /  " + d.lo + "°   "
                          + (wmoText[d.code] || ""),
                    icon: "waybar-weather/" + (wmoIcons[d.code] || "cloud") + ".svg",
                    enabled: false
                });
            }
        }
        bar.showMenu(root, rows);
    }

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
                      root.place = data.results[0].name
                          + (data.results[0].country
                             ? ", " + data.results[0].country : "");
                      root.refresh();
                  });
            return;
        }
        // No city configured: geolocate by IP, the same fallback the plugin
        // used. Wrong by a few miles never mattered for a temperature.
        fetch("http://ip-api.com/json/?fields=lat,lon,city,country", data => {
            if (data.lat === undefined)
                return;
            root.lat = data.lat;
            root.lon = data.lon;
            root.place = data.city
                ? data.city + (data.country ? ", " + data.country : "")
                : "";
            root.refresh();
        });
    }

    function refresh() {
        if (lat === 0 && lon === 0)
            return;
        // The daily block rides along on the request that was already being
        // made: one round trip, and the popover has something to show the
        // moment it is opened rather than starting a fetch on click.
        fetch("https://api.open-meteo.com/v1/forecast?latitude=" + lat.toFixed(4)
              + "&longitude=" + lon.toFixed(4)
              + "&current=temperature_2m,is_day,weather_code"
              + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
              + "&forecast_days=4&timezone=auto",
              data => {
                  if (!data.current)
                      return;
                  root.tempC = Math.round(data.current.temperature_2m);
                  root.code = data.current.weather_code;
                  root.isDay = data.current.is_day === 1;
                  root.valid = true;

                  const d = data.daily;
                  if (!d || !d.time)
                      return;
                  const days = [];
                  for (let i = 0; i < d.time.length; i++) {
                      days.push({
                          day: i === 0 ? "Today"
                             : Qt.formatDate(new Date(d.time[i]), "ddd"),
                          code: d.weather_code[i],
                          hi: Math.round(d.temperature_2m_max[i]),
                          lo: Math.round(d.temperature_2m_min[i])
                      });
                  }
                  root.forecast = days;
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
