(() => {
  "use strict";

  const internals = window.CAMPER_TRACKER_INTERNALS;
  if (!internals?.client) return;

  const client = internals.client;
  const state = internals.state;
  const devices = new Map();
  const visibility = new Map();
  const markers = new Map();
  const activityCharts = [];
  let sessions = [];
  let selectedSessionId = "";
  let primaryTrackerId = "";
  let requestToken = 0;

  const $ = id => document.getElementById(id);
  const number = value => {
    if (value == null || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };
  const format = (value, digits = 0) => value == null
    ? "—"
    : Number(value).toLocaleString("nl-NL", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  const relative = value => {
    if (!value) return "onbekend";
    const minutes = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 60000));
    if (minutes < 1) return "zojuist";
    if (minutes < 60) return `${minutes} min geleden`;
    const hours = Math.round(minutes / 60);
    return hours < 48 ? `${hours} uur geleden` : `${Math.round(hours / 24)} dagen geleden`;
  };
  const duration = session => {
    const start = new Date(session.started_at).getTime();
    const end = new Date(session.ended_at || session.latest_sample_at).getTime();
    if (!Number.isFinite(start) || !Number.isFinite(end)) return "—";
    const seconds = Math.max(0, Math.round((end - start) / 1000));
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds % 3600 / 60);
    return hours ? `${hours}u ${String(minutes).padStart(2, "0")}m` : `${minutes} min`;
  };
  const safeId = id => String(id).replace(/[^a-zA-Z0-9_-]/g, "");
  const palette = ["#7c3aed", "#c2410c", "#0369a1", "#a21caf", "#4d7c0f", "#b91c1c"];
  const hash = value => [...String(value)].reduce((result, char) => ((result * 31) + char.charCodeAt(0)) >>> 0, 0);
  const deviceColor = device => {
    if (device.device_kind === "camper_gateway") return "#27ad7b";
    if (!primaryTrackerId) {
      const trackers = [...devices.values()].filter(item => item.device_kind === "wear_tracker")
        .sort((left, right) => String(left.registered_at || "").localeCompare(String(right.registered_at || ""))
          || String(left.device_id).localeCompare(String(right.device_id)));
      primaryTrackerId = trackers[0]?.device_id || "";
    }
    if (primaryTrackerId === device.device_id) return "#2f80ed";
    return palette[hash(device.device_id) % palette.length];
  };
  const cleanSegments = value => Array.isArray(value)
    ? value.map(segment => Array.isArray(segment)
      ? segment.filter(point => Array.isArray(point) && point.length === 2
        && number(point[0]) != null && number(point[1]) != null
        && Number(point[0]) >= -180 && Number(point[0]) <= 180
        && Number(point[1]) >= -90 && Number(point[1]) <= 90)
        .map(point => [Number(point[0]), Number(point[1])])
      : []).filter(segment => segment.length >= 2)
    : [];

  function routeData(device) {
    return {
      type: "FeatureCollection",
      features: device.route_segments.map(coordinates => ({
        type: "Feature",
        properties: { deviceId: device.device_id },
        geometry: { type: "LineString", coordinates }
      }))
    };
  }

  function updateMapDevices(fit = false) {
    const map = state.map;
    if (!map || !map.isStyleLoaded()) {
      if (map) map.once("load", () => updateMapDevices(fit));
      return;
    }
    const currentIds = new Set([...devices.keys()].filter(id => devices.get(id).device_kind !== "camper_gateway"));
    for (const [deviceId, device] of devices) {
      if (device.device_kind === "camper_gateway") continue;
      const suffix = safeId(deviceId);
      const sourceId = `tracker-route-${suffix}`;
      const layerId = `tracker-route-${suffix}`;
      const visible = visibility.get(deviceId) !== false;
      let source = map.getSource(sourceId);
      if (!source) {
        map.addSource(sourceId, { type: "geojson", data: routeData(device) });
        map.addLayer({
          id: layerId,
          type: "line",
          source: sourceId,
          layout: { "line-cap": "round", "line-join": "round", visibility: visible ? "visible" : "none" },
          paint: { "line-color": deviceColor(device), "line-width": 4, "line-opacity": 0.9 }
        });
      } else {
        source.setData(routeData(device));
        map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none");
        map.setPaintProperty(layerId, "line-color", deviceColor(device));
      }
    }
    for (const layer of map.getStyle().layers || []) {
      if (!layer.id.startsWith("tracker-route-")) continue;
      const matching = [...currentIds].some(id => layer.id === `tracker-route-${safeId(id)}`);
      if (!matching) {
        map.removeLayer(layer.id);
        if (map.getSource(layer.source)) map.removeSource(layer.source);
      }
    }
    if (fit && window.maplibregl) {
      const bounds = new maplibregl.LngLatBounds();
      let hasPoint = false;
      for (const [deviceId, device] of devices) {
        if (visibility.get(deviceId) === false) continue;
        for (const segment of device.route_segments) {
          for (const point of segment) {
            bounds.extend(point);
            hasPoint = true;
          }
        }
      }
      if (hasPoint) map.fitBounds(bounds, { padding: innerWidth <= 620 ? 35 : 55, maxZoom: 15, duration: 500 });
    }
  }

  function updateMarker(location) {
    if (!state.map || !window.maplibregl || location.device_kind === "camper_gateway") return;
    const longitude = number(location.longitude);
    const latitude = number(location.latitude);
    if (longitude == null || latitude == null || longitude < -180 || longitude > 180 || latitude < -90 || latitude > 90) return;
    let marker = markers.get(location.device_id);
    if (!marker) {
      const element = document.createElement("div");
      element.className = "tracker-marker";
      element.style.background = deviceColor(location);
      element.textContent = "⌚";
      element.title = location.device_name || "Movement Tracker";
      marker = new maplibregl.Marker({ element }).setLngLat([longitude, latitude]).addTo(state.map);
      markers.set(location.device_id, marker);
    } else {
      marker.setLngLat([longitude, latitude]);
    }
    marker.getElement().hidden = visibility.get(location.device_id) === false;
  }

  function toggleDevice(deviceId, visible) {
    visibility.set(deviceId, visible);
    const device = devices.get(deviceId);
    if (state.map?.isStyleLoaded()) {
      if (device?.device_kind === "camper_gateway" && state.map.getLayer("gps-route")) {
        state.map.setLayoutProperty("gps-route", "visibility", visible ? "visible" : "none");
        if (state.marker) state.marker.getElement().hidden = !visible;
      } else {
        const layerId = `tracker-route-${safeId(deviceId)}`;
        if (state.map.getLayer(layerId)) state.map.setLayoutProperty(layerId, "visibility", visible ? "visible" : "none");
        if (markers.has(deviceId)) markers.get(deviceId).getElement().hidden = !visible;
      }
    }
  }

  function renderDeviceControls() {
    const controls = [...devices.values()].map(device => {
      const label = document.createElement("label");
      label.className = "route-device";
      label.style.setProperty("--device-color", deviceColor(device));
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = visibility.get(device.device_id) !== false;
      checkbox.setAttribute("aria-label", `${device.device_name} ${checkbox.checked ? "verbergen" : "tonen"}`);
      checkbox.addEventListener("change", () => {
        toggleDevice(device.device_id, checkbox.checked);
        checkbox.setAttribute("aria-label", `${device.device_name} ${checkbox.checked ? "verbergen" : "tonen"}`);
      });
      const dot = document.createElement("span");
      dot.className = "route-device-dot";
      dot.setAttribute("aria-hidden", "true");
      const main = document.createElement("span");
      main.className = "route-device-main";
      const name = document.createElement("strong");
      name.textContent = device.device_name || "GPS-apparaat";
      const details = document.createElement("small");
      details.textContent = `${format(number(device.distance_km), 1)} km • ${relative(device.latest_fix?.recorded_at)}`;
      main.append(name, details);
      label.append(checkbox, dot, main);
      return label;
    });
    $("routeDevices").replaceChildren(...controls);
  }

  function handleLocationHistory(event) {
    const rows = Array.isArray(event.detail?.devices) ? event.detail.devices : [];
    devices.clear();
    for (const row of rows) {
      if (!row || typeof row.device_id !== "string" || typeof row.device_kind !== "string") continue;
      const distanceKm = number(row.distance_km);
      if (distanceKm == null || distanceKm < 0) continue;
      devices.set(row.device_id, { ...row, distance_km: distanceKm, route_segments: cleanSegments(row.route_segments) });
      if (!visibility.has(row.device_id)) visibility.set(row.device_id, true);
    }
    if (!primaryTrackerId) deviceColor([...devices.values()].find(device => device.device_kind === "wear_tracker") || {});
    renderDeviceControls();
    updateMapDevices(true);
    for (const device of devices.values()) {
      if (device.latest_fix) updateMarker({ ...device.latest_fix, ...device });
    }
  }

  function handleDashboard(event) {
    const latest = Array.isArray(event.detail?.latest_locations) ? event.detail.latest_locations : [];
    const trackers = latest.filter(item => item?.device_kind === "wear_tracker" && typeof item.device_id === "string")
      .sort((left, right) => String(left.registered_at || "").localeCompare(String(right.registered_at || ""))
        || left.device_id.localeCompare(right.device_id));
    const nextPrimary = trackers[0]?.device_id || primaryTrackerId;
    const colorOrderChanged = nextPrimary !== primaryTrackerId;
    primaryTrackerId = nextPrimary;
    for (const location of latest) {
      if (!location || typeof location.device_id !== "string") continue;
      const existing = devices.get(location.device_id);
      updateMarker({ ...(existing || {}), ...location });
    }
    if (colorOrderChanged) {
      for (const [deviceId, marker] of markers) marker.getElement().style.background = deviceColor(devices.get(deviceId) || latest.find(item => item.device_id === deviceId) || {});
      renderDeviceControls();
      updateMapDevices();
    }
  }

  function clearCharts() {
    while (activityCharts.length) activityCharts.pop().destroy();
  }

  function chartPanel(title, key, label, color, rows, options = {}) {
    const panel = document.createElement("section");
    panel.className = "activity-chart";
    const heading = document.createElement("h4");
    heading.textContent = title;
    const clean = rows.map(row => ({ x: new Date(row.recorded_at).getTime(), y: options.value ? options.value(row) : number(row[key]) }))
      .filter(point => Number.isFinite(point.x) && point.y != null);
    if (!clean.length) {
      const empty = document.createElement("p");
      empty.className = "activity-empty";
      empty.textContent = "Geen metingen";
      panel.append(heading, empty);
      return panel;
    }
    const canvas = document.createElement("canvas");
    const values = clean.map(point => point.y);
    const describe = value => options.tooltip ? options.tooltip(value) : `${format(value, options.digits || 0)} ${options.unit || ""}`;
    const summary = `${label}: ${clean.length} metingen, minimum ${describe(Math.min(...values))}, maximum ${describe(Math.max(...values))}.`;
    canvas.setAttribute("role", "img");
    canvas.setAttribute("aria-label", summary);
    panel.append(heading, canvas);
    if (!window.Chart) return panel;
    const chart = new Chart(canvas, {
      type: "line",
      data: { datasets: [{ label, data: clean, borderColor: color, backgroundColor: `${color}18`, borderWidth: 2, pointRadius: 0, pointHitRadius: 10, tension: 0.15, spanGaps: false, fill: true }] },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        normalized: true,
        interaction: { mode: "nearest", axis: "x", intersect: false },
        plugins: { legend: { display: false }, tooltip: { callbacks: { title: items => items.length ? new Date(items[0].parsed.x).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "", label: context => `${label}: ${options.tooltip ? options.tooltip(context.parsed.y) : `${format(context.parsed.y, options.digits || 0)} ${options.unit || ""}`}` } } },
        scales: { x: { type: "linear", grid: { display: false }, ticks: { maxTicksLimit: 4, callback: value => new Date(Number(value)).toLocaleTimeString("nl-NL", { hour: "2-digit", minute: "2-digit" }) } }, y: { beginAtZero: options.beginAtZero === true, ticks: { callback: value => options.tick ? options.tick(value) : `${format(value, options.digits || 0)}${options.unit ? ` ${options.unit}` : ""}` } } }
      }
    });
    activityCharts.push(chart);
    return panel;
  }

  function summaryStat(label, value) {
    const item = document.createElement("div");
    item.className = "activity-stat";
    const name = document.createElement("span");
    name.textContent = label;
    const result = document.createElement("strong");
    result.textContent = value;
    item.append(name, result);
    return item;
  }

  async function loadMetrics(session) {
    const token = ++requestToken;
    clearCharts();
    $("activityContent").className = "activity-empty";
    $("activityContent").textContent = "Meetwaarden laden…";
    const { data, error } = await client.rpc("get_tracking_metrics", { p_session_id: session.id });
    if (error) throw error;
    if (token !== requestToken) return;
    if (!Array.isArray(data)) throw new Error("ongeldige meetreeks");
    const rows = data.filter(row => row && Number.isFinite(new Date(row.recorded_at).getTime()));
    const summary = document.createElement("div");
    summary.className = "activity-summary";
    summary.append(
      summaryStat("Duur", duration(session)),
      summaryStat("Afstand", `${format(number(session.distance_m) / 1000, 2)} km`),
      summaryStat("Stappen", format(number(session.steps))),
      summaryStat("Calorieën", `${format(number(session.calories_kcal))} kcal`),
      summaryStat("Hoogte +/−", `${format(number(session.elevation_gain_m))} / ${format(number(session.elevation_loss_m))} m`),
      summaryStat("Hartslag gem./max", `${format(number(session.average_heart_rate_bpm))} / ${format(number(session.max_heart_rate_bpm))} bpm`)
    );
    const charts = document.createElement("div");
    charts.className = "activity-charts";
    const paceText = value => {
      if (!Number.isFinite(value) || value <= 0) return "—";
      const minutes = Math.floor(value / 60);
      return `${minutes}:${String(Math.round(value % 60)).padStart(2, "0")}`;
    };
    charts.append(
      chartPanel("Hartslag", "heart_rate_bpm", "Hartslag", "#dc2626", rows, { unit: "bpm", beginAtZero: false }),
      chartPanel("Tempo / snelheid", "pace_seconds_per_km", "Tempo", "#2f80ed", rows, { unit: "min/km", value: row => number(row.pace_seconds_per_km) ?? (number(row.speed_mps) > 0 ? 1000 / number(row.speed_mps) : null), tick: paceText, tooltip: value => `${paceText(value)} min/km` }),
      chartPanel("Hoogte", "elevation_m", "Hoogte", "#7c3aed", rows, { unit: "m", digits: 1 }),
      chartPanel("Cadans", "cadence_spm", "Cadans", "#c2410c", rows, { unit: "stappen/min", digits: 0, beginAtZero: true })
    );
    $("activityContent").className = "";
    $("activityContent").replaceChildren(summary, charts);
    $("activityDelay").textContent = session.ended_at
      ? `Afgerond • laatst bijgewerkt ${relative(session.latest_sample_at)}`
      : `Actief • synchronisatie kan circa vijf minuten achterlopen • ${relative(session.latest_sample_at)}`;
  }

  async function selectSession(id) {
    selectedSessionId = id;
    const session = sessions.find(item => item.id === id);
    if (!session) {
      clearCharts();
      $("activityContent").className = "activity-empty";
      $("activityContent").textContent = "Geen Watch-activiteiten in deze periode.";
      return;
    }
    try {
      await loadMetrics(session);
    } catch (error) {
      clearCharts();
      $("activityContent").className = "activity-empty";
      $("activityContent").textContent = `Activiteitsmetingen niet beschikbaar: ${error.message}`;
    }
  }

  async function loadPeriod(range) {
    const token = ++requestToken;
    $("activityContent").className = "activity-empty";
    $("activityContent").textContent = "Activiteiten laden…";
    try {
      const { data, error } = await client.rpc("get_tracking_sessions", { p_range: range });
      if (error) throw error;
      if (token !== requestToken) return;
      if (!Array.isArray(data)) throw new Error("ongeldige activiteitenlijst");
      sessions = data.filter(item => item && typeof item.id === "string" && Number.isFinite(new Date(item.started_at).getTime()))
        .sort((left, right) => new Date(right.started_at) - new Date(left.started_at));
      const options = sessions.map(session => {
        const option = document.createElement("option");
        option.value = session.id;
        const started = new Date(session.started_at).toLocaleString("nl-NL", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
        option.textContent = `${session.ended_at ? "" : "Actief • "}${session.device_name || "Movement Tracker"} • ${started}`;
        return option;
      });
      if (!sessions.length) {
        const option = document.createElement("option");
        option.value = "";
        option.textContent = "Geen activiteiten";
        options.push(option);
      }
      $("activitySession").replaceChildren(...options);
      if (!sessions.some(item => item.id === selectedSessionId)) selectedSessionId = sessions[0]?.id || "";
      $("activitySession").value = selectedSessionId;
      await selectSession(selectedSessionId);
    } catch (error) {
      if (token !== requestToken) return;
      sessions = [];
      clearCharts();
      const option = document.createElement("option");
      option.value = "";
      option.textContent = "Niet beschikbaar";
      $("activitySession").replaceChildren(option);
      $("activityContent").className = "activity-empty";
      $("activityContent").textContent = `Activiteiten niet beschikbaar: ${error.message}`;
    }
  }

  $("activitySession").addEventListener("change", event => selectSession(event.target.value));
  window.addEventListener("camper-location-history", handleLocationHistory);
  window.addEventListener("camper-dashboard", handleDashboard);
  window.CamperMovement = { loadPeriod };
})();
