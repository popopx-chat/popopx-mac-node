/**
 * Typed failure vocabulary for the node bridge.
 *
 * The point of one union instead of ad-hoc `Error`s is that a plugin can decide what is
 * worth retrying without string-matching: transport codes may be retried once, semantic
 * codes must never be, and `lockdownDenied` must never look like a transport failure.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

export type BridgeErrorCode =
  // Transport / authentication.
  | "tokenRejected"
  | "methodNotAllowed"
  | "lengthRequired"
  | "payloadTooLarge"
  | "nodeUnreachable"
  | "nodeBusy"
  | "badResponse"
  // Grammar, decided before any socket is opened.
  | "malformedCommand"
  | "unknownService"
  | "emptyAction"
  | "payloadBudget"
  // Policy.
  | "lockdownDenied"
  | "secretRequired"
  | "nonLoopbackTarget"
  | "inFlightLimit";

/**
 * Codes worth *considering* a retry for. Not a licence: a retry additionally requires
 * `mayHaveExecuted === false`, because the node has real side effects (`chrono_ark seal`,
 * `creator_paywall_hub grant`) and a request that timed out may already have run.
 */
const MAY_RETRY: readonly BridgeErrorCode[] = ["nodeUnreachable", "nodeBusy"];

export function isRetryable(code: BridgeErrorCode): boolean {
  return MAY_RETRY.includes(code);
}

/** Conservative default when the thrower does not say. */
function codeMayHaveExecuted(code: BridgeErrorCode): boolean {
  switch (code) {
    case "nodeUnreachable":
    case "nodeBusy":
    case "badResponse":
      // Either the request may have reached an engine before the answer was lost, or it did and only
      // the reply failed.
      return true;
    default:
      // Grammar, policy, 401/405/411/413: rejected before an engine ran.
      return false;
  }
}

export class BridgeError extends Error {
  readonly code: BridgeErrorCode;
  readonly status?: number;
  readonly detail?: string;
  readonly mayHaveExecuted: boolean;

  constructor(
    code: BridgeErrorCode,
    message: string,
    init: { status?: number; detail?: string; mayHaveExecuted?: boolean } = {}
  ) {
    super(message);
    this.name = "BridgeError";
    this.code = code;
    if (init.status !== undefined) this.status = init.status;
    if (init.detail !== undefined) this.detail = init.detail;
    this.mayHaveExecuted = init.mayHaveExecuted ?? codeMayHaveExecuted(code);
  }

  /** True when the node may already have acted, so a caller must not resend blindly. */
  get outcomeUnknown(): boolean {
    return this.mayHaveExecuted;
  }
}

export function isGrammarCode(code: BridgeErrorCode): boolean {
  return (
    code === "malformedCommand" ||
    code === "unknownService" ||
    code === "emptyAction" ||
    code === "payloadBudget"
  );
}

export function isPolicyCode(code: BridgeErrorCode): boolean {
  return code === "lockdownDenied" || code === "secretRequired" || code === "nonLoopbackTarget";
}

export function describeError(error: unknown): string {
  if (error instanceof BridgeError) {
    const status = error.status === undefined ? "" : ` (HTTP ${error.status})`;
    const detail = error.detail === undefined || error.detail === "" ? "" : `\n  ${error.detail}`;
    return `${error.code}${status}: ${error.message}${detail}`;
  }
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}
