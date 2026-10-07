/**
 * 真机 lease 定时器：单发 setTimeout，fire 后由 client 重新排程。
 */

import { LeaseTimer } from './Transport';

export class SystemLeaseTimer implements LeaseTimer {
  private handle: number = -1;

  start(intervalMs: number, fire: () => void): void {
    this.stop();
    this.handle = setTimeout(fire, intervalMs);
  }

  stop(): void {
    if (this.handle >= 0) {
      clearTimeout(this.handle);
      this.handle = -1;
    }
  }
}
