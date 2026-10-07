/**
 * 内存探针（M13）：hidebug 周期采样进程内存，给「长会话/大消息不打爆前端」
 * 一个可复现的观察手段（此前 M8 挂账「364 条 text_delta 待观察」其实没有
 * 观察工具，全凭体感）。
 *
 * - 采样：PSS（物理驻留）/ native heap（分配器视角）/ 峰值 PSS，5s 一拍；
 * - 出口：hilog 落账（后接 DevEco Profiler 对时序）+ AppStorage 广播
 *   （设置页调试卡实时显示）；
 * - hidebug 是调试面 API：任何一项抛错（系统裁剪/受限 profile）即静默停表，
 *   不影响业务。采样本身无权限要求、量级在微秒级，release 常驻也无碍。
 */

import { hilog, hidebug } from '@kit.PerformanceAnalysisKit';
import { QaqhState } from '../model/QaqhState';

const SAMPLE_INTERVAL_MS: number = 5000;
const HILOG_DOMAIN: number = 0x0;
const HILOG_TAG: string = 'QaqhMem';

export class MemoryProbe {
  private timer: number = -1;
  private peakPssKb: number = 0;

  start(): void {
    if (this.timer >= 0) {
      return;
    }
    this.sample();
    this.timer = setInterval((): void => this.sample(), SAMPLE_INTERVAL_MS);
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private sample(): void {
    try {
      // d.ts 返回 bigint（字节），ArkTS 下转 Number 走 KB 口径（与 mallinfo 一致）。
      const pssKb: number = Number(hidebug.getPss()) / 1024;
      const heapKb: number = Number(hidebug.getNativeHeapAllocatedSize()) / 1024;
      if (pssKb > this.peakPssKb) {
        this.peakPssKb = pssKb;
      }
      AppStorage.setOrCreate(QaqhState.PERF_PSS, MemoryProbe.mb(pssKb));
      AppStorage.setOrCreate(QaqhState.PERF_NATIVE, MemoryProbe.mb(heapKb));
      AppStorage.setOrCreate(QaqhState.PERF_PEAK, MemoryProbe.mb(this.peakPssKb));
      hilog.info(HILOG_DOMAIN, HILOG_TAG,
        'pss=%{public}fMB nativeHeap=%{public}fMB peakPss=%{public}fMB',
        pssKb / 1024, heapKb / 1024, this.peakPssKb / 1024);
    } catch (error) {
      // 环境不支持：停表静默退出（探针永远不能成为新的故障面）。
      void (error as Error);
      this.stop();
    }
  }

  private static mb(kb: number): string {
    return (kb / 1024).toFixed(1);
  }
}
