const required = [
  "DATABASE_URL",
  "APPLE_BUNDLE_ID",
  "SESSION_SECRET",
  "STRIPE_SECRET_KEY",
  "STRIPE_WEBHOOK_SECRET",
  "STRIPE_CONNECT_COUNTRY",
  "DRIVER_ONBOARDING_RETURN_URL",
  "DRIVER_ONBOARDING_REFRESH_URL",
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
  if (!/^[a-z]{3}$/.test(currency)) {
    throw new Error("STRIPE_CURRENCY must be a three-letter ISO currency code.");
  }
  for (const name of ["DRIVER_ONBOARDING_RETURN_URL", "DRIVER_ONBOARDING_REFRESH_URL"]) {
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

  return {
    databaseUrl: env.DATABASE_URL,
    appleBundleId: env.APPLE_BUNDLE_ID,
    sessionSecret: env.SESSION_SECRET,
    stripeSecretKey: env.STRIPE_SECRET_KEY,
    stripeWebhookSecret: env.STRIPE_WEBHOOK_SECRET,
    stripeConnectCountry: env.STRIPE_CONNECT_COUNTRY,
    driverOnboardingReturnUrl: env.DRIVER_ONBOARDING_RETURN_URL,
    driverOnboardingRefreshUrl: env.DRIVER_ONBOARDING_REFRESH_URL,
    port,
    ridePrices: {
      "tryps-go": 1250,
      "tryps-comfort": 1820,
      "tryps-xl": 2480,
    },
    currency: "usd",
    applicationFeeBasisPoints,
    matchingRadiusMeters: 10000,
    paymentReservationMinutes: 20,
    currency,
  };
}
