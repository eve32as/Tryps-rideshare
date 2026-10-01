"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { getWeatherDemandForecast, summarizeWeatherForecast } = require("../weather");

const now = Date.parse("2026-10-01T12:00:00Z");

function hourly(overrides = {}) {
  return {
    time: [
      "2026-10-01T11:00Z",
      "2026-10-01T12:00Z",
      "2026-10-01T13:00Z",
      "2026-10-01T14:00Z",
      "2026-10-01T16:00Z",
    ],
    precipitation_probability: [100, 0, 0, 0, 100],
    rain: [10, 0, 0, 0, 10],
    snowfall: [0, 0, 0, 0, 0],
    wind_speed_10m: [10, 10, 10, 10, 10],
    weather_code: [65, 0, 0, 0, 65],
    ...overrides,
  };
}

test("estimates no weather demand uplift for clear weather within the forecast horizon", () => {
  assert.deepEqual(
    summarizeWeatherForecast(hourly({
      precipitation_probability: [100, 0, 0, 0, 100],
      rain: [10, 0, 0, 0, 10],
      weather_code: [65, 0, 0, 0, 65],
    }), now),
    { condition: "CLEAR", demandUpliftPercent: 0, horizonHours: 3, available: true },
  );
});

test("classifies rain, snow, wind, and severe weather with bounded uplift estimates", () => {
  const cases = [
    [{ rain: [0, 0.5, 0, 0, 0], weather_code: [0, 0, 0, 0, 0] }, "RAIN", 10],
    [{ snowfall: [0, 0.2, 0, 0, 0] }, "SNOW", 20],
    [{ wind_speed_10m: [10, 45, 0, 0, 0] }, "WIND", 15],
    [{ weather_code: [0, 95, 0, 0, 0] }, "SEVERE", 30],
    [{ precipitation_probability: [0, 60, 0, 0, 0] }, "RAIN_POSSIBLE", 5],
  ];
  for (const [overrides, condition, demandUpliftPercent] of cases) {
    const result = summarizeWeatherForecast(hourly(overrides), now);
    assert.equal(result.condition, condition);
    assert.equal(result.demandUpliftPercent, demandUpliftPercent);
    assert.ok(result.demandUpliftPercent <= 30);
  }
});

test("returns unavailable when there are no forecast hours or malformed data", () => {
  assert.equal(summarizeWeatherForecast({}, now).available, false);
  assert.equal(summarizeWeatherForecast({ time: ["bad-time"] }, now).condition, "UNAVAILABLE");
});

test("uses a bounded provider request and degrades gracefully on provider/network errors", async () => {
  let requestedUrl;
  const result = await getWeatherDemandForecast(
    { latitude: 37.7, longitude: -122.4 },
    async (url, options) => {
      requestedUrl = new URL(url);
      assert.ok(options.signal);
      return { ok: true, json: async () => ({ hourly: hourly() }) };
    },
    now,
  );
  assert.equal(requestedUrl.hostname, "api.open-meteo.com");
  assert.equal(requestedUrl.searchParams.get("forecast_days"), "2");
  assert.equal(result.available, true);
  assert.equal((await getWeatherDemandForecast({ latitude: 0, longitude: 0 }, async () => ({ ok: false }))).available, false);
  assert.equal((await getWeatherDemandForecast({ latitude: 91, longitude: 0 })).available, false);
});
