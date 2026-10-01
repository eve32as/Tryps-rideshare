"use strict";

const MAX_SPLIT_PARTICIPANTS = 4;
const PAYMENT_METHODS = new Set(["CASH", "SIMULATED_CARD", "RIDE_PASS"]);

function validatePaymentRequest(method, participantEmails, passId) {
  if (!PAYMENT_METHODS.has(method)) throw new Error("Unsupported payment method");
  if (!Array.isArray(participantEmails) || participantEmails.length > MAX_SPLIT_PARTICIPANTS) {
    throw new Error("A split can include at most four other riders");
  }
  const emails = participantEmails.map((email) => {
    if (typeof email !== "string") throw new Error("Split participant emails are invalid");
    const normalized = email.trim().toLowerCase();
    if (normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) {
      throw new Error("Enter a valid email for each split participant");
    }
    return normalized;
  });
  if (new Set(emails).size !== emails.length) throw new Error("Split participant emails must be unique");
  if (emails.length > 0 && method !== "CASH") throw new Error("Split payments currently require cash");
  if (method === "RIDE_PASS" && (emails.length > 0 || typeof passId !== "string" || !passId)) {
    throw new Error("Select one valid ride pass without split payments");
  }
  if (method !== "RIDE_PASS" && passId != null) throw new Error("A ride pass requires the ride-pass payment method");
  return { method, participantEmails: emails, passId: passId ?? null };
}

function allocateEqualShares(amountCents, payerIds) {
  if (!Number.isSafeInteger(amountCents) || amountCents < 0 ||
      !Array.isArray(payerIds) || payerIds.length < 1 || payerIds.length > MAX_SPLIT_PARTICIPANTS + 1 ||
      payerIds.some((id) => typeof id !== "string" || !id) ||
      new Set(payerIds).size !== payerIds.length) {
    throw new Error("Fare or split participants are invalid");
  }
  const baseShare = Math.floor(amountCents / payerIds.length);
  const remainder = amountCents % payerIds.length;
  return payerIds.map((payerId, index) => ({
    payerId,
    amountCents: baseShare + (index < remainder ? 1 : 0),
  }));
}

function isRidePassUsable(pass, nowMillis) {
  return pass && Number.isSafeInteger(pass.remainingRides) && pass.remainingRides > 0 &&
    Number.isFinite(pass.expiresAtMillis) && pass.expiresAtMillis > nowMillis;
}

module.exports = { allocateEqualShares, isRidePassUsable, validatePaymentRequest };
