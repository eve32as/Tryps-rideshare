"use strict";

const FORECAST_HOURS = 3;
const FORECAST_TIMEOUT_MILLIS = 2_500;

async function getWeatherDemandForecast(point, fetchImpl = fetch, nowMillis = Date.now()) {
  if (!isValidPoint(point)) return unavailableForecast();
  const url = new URL("https://api.open-meteo.com/v1/forecast");
  url.search = new URLSearchParams({
    latitude: String(point.latitude),
    longitude: String(point.longitude),
    hourly: "precipitation_probability,rain,snowfall,wind_speed_10m,weather_code",
    forecast_days: "2",
    timezone: "UTC",
  });
  try {
    const response = await fetchImpl(url, { signal: AbortSignal.timeout(FORECAST_TIMEOUT_MILLIS) });
    if (!response.ok) return unavailableForecast();
    const payload = await response.json();
    return summarizeWeatherForecast(payload?.hourly, nowMillis);
  } catch {
    return unavailableForecast();
  }
}

function summarizeWeatherForecast(hourly, nowMillis) {
  const times = hourly?.time;
  const fields = [
    hourly?.precipitation_probability,
    hourly?.rain,
    hourly?.snowfall,
    hourly?.wind_speed_10m,
    hourly?.weather_code,
  ];
  if (!Array.isArray(times) || !Number.isFinite(nowMillis) ||
      fields.some((field) => !Array.isArray(field) || field.length < times.length)) {
    return unavailableForecast();
  }
  const forecastHours = [];
  for (let index = 0; index < times.length; index += 1) {
    const time = times[index];
    const timestamp = Date.parse(
      typeof time === "string" && !/(?:Z|[+-]\d{2}:\d{2})$/i.test(time) ? `${time}Z` : time,
    );
    const hoursAhead = (timestamp - nowMillis) / 3_600_000;
    if (Number.isFinite(timestamp) && hoursAhead >= 0 && hoursAhead < FORECAST_HOURS) {
      forecastHours.push({
        probability: validNumber(hourly.precipitation_probability?.[index]),
        rainMm: validNumber(hourly.rain?.[index]),
        snowfallCm: validNumber(hourly.snowfall?.[index]),
        windKph: validNumber(hourly.wind_speed_10m?.[index]),
        code: validNumber(hourly.weather_code?.[index]),
      });
    }
  }
  if (forecastHours.length === 0) return unavailableForecast();

  const maxProbability = Math.max(...forecastHours.map((hour) => hour.probability));
  const maxRain = Math.max(...forecastHours.map((hour) => hour.rainMm));
  const maxSnow = Math.max(...forecastHours.map((hour) => hour.snowfallCm));
  const maxWind = Math.max(...forecastHours.map((hour) => hour.windKph));
  const maxCode = Math.max(...forecastHours.map((hour) => hour.code));
  let condition = "CLEAR";
  let demandUpliftPercent = 0;
  if (maxCode >= 95 || maxRain >= 7) {
    condition = "SEVERE";
    demandUpliftPercent = 30;
  } else if (maxSnow >= 0.2 || [71, 73, 75, 77, 85, 86].some((code) =>
    forecastHours.some((hour) => hour.code === code))) {
    condition = "SNOW";
    demandUpliftPercent = 20;
  } else if (maxWind >= 45) {
    condition = "WIND";
    demandUpliftPercent = 15;
  } else if (maxRain >= 0.5 || [61, 63, 65, 66, 67, 80, 81, 82].some((code) =>
    forecastHours.some((hour) => hour.code === code))) {
    condition = "RAIN";
    demandUpliftPercent = 10;
  } else if (maxProbability >= 60) {
    condition = "RAIN_POSSIBLE";
    demandUpliftPercent = 5;
  }

  return {
    condition,
    demandUpliftPercent,
    horizonHours: FORECAST_HOURS,
    available: true,
  };
}

function isValidPoint(point) {
  return Number.isFinite(point?.latitude) && point.latitude >= -90 && point.latitude <= 90 &&
    Number.isFinite(point?.longitude) && point.longitude >= -180 && point.longitude <= 180;
}

function validNumber(value) {
  return Number.isFinite(value) && value >= 0 ? value : 0;
}

function unavailableForecast() {
  return { condition: "UNAVAILABLE", demandUpliftPercent: 0, horizonHours: FORECAST_HOURS, available: false };
}

module.exports = { getWeatherDemandForecast, summarizeWeatherForecast };
