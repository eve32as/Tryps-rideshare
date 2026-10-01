const required = [
  "DATABASE_URL",
  "APPLE_BUNDLE_ID",
  "SESSION_SECRET",
  "STRIPE_SECRET_KEY",
  "STRIPE_WEBHOOK_SECRET",
  "GOOGLE_ROUTES_API_KEY",
  "STRIPE_CONNECT_COUNTRY",
  "DRIVER_ONBOARDING_RETURN_URL",
  "DRIVER_ONBOARDING_REFRESH_URL",
  "TRIP_SHARE_BASE_URL",
  "PLATFORM_FEE_BPS",
];

export function readConfig(env = process.env) {
  const missing = required.filter((name) => !env[name]);
  if (missing.length) {
    throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  }
  if (Buffer.byteLength(env.SESSION_SECRET, "utf8") < 32) {
    throw new Error("SESSION_SECRET must contain at least 32 bytes.");
  }
  const applicationFeeBasisPoints = Number(env.PLATFORM_FEE_BPS);
  if (!Number.isInteger(applicationFeeBasisPoints) || applicationFeeBasisPoints < 0 || applicationFeeBasisPoints > 5000) {
    throw new Error("PLATFORM_FEE_BPS must be an integer between 0 and 5000.");
  }
  const currency = (env.STRIPE_CURRENCY ?? "usd").toLowerCase();
  if (currency !== "usd") {
    throw new Error("The current sample fares support USD only.");
  }
  for (const name of ["DRIVER_ONBOARDING_RETURN_URL", "DRIVER_ONBOARDING_REFRESH_URL", "TRIP_SHARE_BASE_URL"]) {
    let url;
    try {
      url = new URL(env[name]);
    } catch {
      throw new Error(`${name} must be an HTTPS URL.`);
    }
    if (url.protocol !== "https:" || url.hostname.endsWith(".invalid")) {
      throw new Error(`${name} must be a real HTTPS URL.`);
    }
  }
  const port = Number(env.PORT ?? 8080);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("PORT must be a valid TCP port.");
  }
  const apnsValues = ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_PRIVATE_KEY", "APNS_HOST"];
  const configuredApnsValues = apnsValues.filter((name) => env[name]);
  if (configuredApnsValues.length > 0 && configuredApnsValues.length !== apnsValues.length) {
    throw new Error("Configure all APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, and APNS_HOST values together.");
  }
  if (env.APNS_HOST && !["api.push.apple.com", "api.sandbox.push.apple.com"].includes(env.APNS_HOST)) {
    throw new Error("APNS_HOST must be an Apple production or sandbox endpoint.");
  }

  const fareBaseCents = Number(env.FARE_BASE_CENTS ?? 300);
  const farePerKmCents = Number(env.FARE_PER_KM_CENTS ?? 150);
  const fareMinimumCents = Number(env.FARE_MINIMUM_CENTS ?? 500);
  if (![fareBaseCents, farePerKmCents, fareMinimumCents].every((amount) =>
    Number.isSafeInteger(amount) && amount > 0)) {
    throw new Error("Fare configuration must use positive cent amounts.");
  }

  return {
    databaseUrl: env.DATABASE_URL,
    appleBundleId: env.APPLE_BUNDLE_ID,
    sessionSecret: env.SESSION_SECRET,
    stripeSecretKey: env.STRIPE_SECRET_KEY,
    stripeWebhookSecret: env.STRIPE_WEBHOOK_SECRET,
    googleRoutesApiKey: env.GOOGLE_ROUTES_API_KEY,
    stripeConnectCountry: env.STRIPE_CONNECT_COUNTRY,
    driverOnboardingReturnUrl: env.DRIVER_ONBOARDING_RETURN_URL,
    driverOnboardingRefreshUrl: env.DRIVER_ONBOARDING_REFRESH_URL,
    tripShareBaseUrl: env.TRIP_SHARE_BASE_URL.replace(/\/+$/, ""),
    apns: env.APNS_HOST ? {
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      privateKey: env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n"),
      host: env.APNS_HOST,
    } : null,
    port,
    farePricing: {
      baseCents: fareBaseCents,
      perKmCents: farePerKmCents,
      minimumCents: fareMinimumCents,
      rideTypeMultipliers: {
        "tryps-go": 1,
        "tryps-comfort": 1.4,
        "tryps-xl": 1.8,
      },
    },
    applicationFeeBasisPoints,
    matchingRadiusMeters: 10000,
    paymentReservationMinutes: 20,
    driverHeartbeatTimeoutSeconds: 120,
    scheduledDispatchLeadMinutes: 15,
    currency,
  };
}
