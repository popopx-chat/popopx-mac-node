/**
 * Public surface of `@popopx/node-bridge`.
 *
 * Everything a plugin needs is re-exported from here, and only from here: the two plugins do not
 * import `./wireCommand.js` directly, so the policy gate in `assertSendable` cannot be bypassed by
 * reaching around the barrel.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

import { ConsoleClient, resolveTarget, type ConsoleOptions, type ConsoleTarget } from "./consoleClient.js";
import { parseWireLine, type ParseResult, type WireCommand } from "./wireCommand.js";
import type { EventStream } from "./eventStream.js";
import type { CommandResult, NodeHealth } from "./consoleClient.js";

export * from "./errors.js";
export * from "./wireCommand.js";
export * from "./consoleClient.js";
export * from "./eventStream.js";

export interface BridgeOptions extends Omit<ConsoleOptions, "target"> {
  /** A tokenised console URL or a bare token; see CONTRACT §2 · 第 2 节. */
  readonly handoff: string;
  readonly env?: NodeJS.ProcessEnv;
}

/**
 * The one-call wiring both plugins use, so neither re-implements target resolution and neither can
 * widen the lockdown policy without passing `allowLockdown` and a secret explicitly.
 */
export class NodeBridge {
  readonly client: ConsoleClient;
  readonly target: ConsoleTarget;

  constructor(options: BridgeOptions) {
    const { handoff, env, ...rest } = options;
    this.target = resolveTarget(handoff, env);
    this.client = new ConsoleClient({ ...rest, target: this.target });
  }

  get origin(): string {
    return this.client.origin;
  }

  get tokenFingerprint(): string {
    return this.client.tokenFingerprint;
  }

  health(): Promise<NodeHealth> {
    return this.client.health();
  }

  snapshot(): Promise<Record<string, unknown>> {
    return this.client.snapshot();
  }

  run(line: string): ReturnType<ConsoleClient["runLine"]> {
    return this.client.runLine(line);
  }

  invoke(command: WireCommand): Promise<CommandResult> {
    return this.client.invoke(command);
  }

  invokeWithRetry(command: WireCommand): Promise<CommandResult> {
    return this.client.invokeWithRetry(command);
  }

  parse(line: string): ParseResult {
    return parseWireLine(line);
  }

  events(signal?: AbortSignal): EventStream {
    return this.client.events(signal);
  }
}
