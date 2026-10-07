/**
 * 敏感动作鉴权抽象（M4）：应答审批（approved=true）前的本地门禁。
 *
 * 设备差异策略（平板没有可信安全代理）：
 * - `UserIamAuthenticator`：探测 FACE / FINGERPRINT 可用则走生物识别；
 *   不可用回退 `UserAuthType.PIN`（系统设备凭据，平板可注册）；
 *   两者都不可用时构造失败，调用方降级 `NoopAuthenticator`（初期直通）。
 * - ATL1 信任级：本端"确认为机主本人"足够，不涉及设备解锁凭据托管的 ATL 级。
 */

import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError } from '@kit.BasicServicesKit';

export interface Authenticator {
  /** 鉴权通过才 resolve；失败/取消/不可用 reject。 */
  authenticate(title: string): Promise<void>;
}

/** 直通实现（初期 / 无任何凭据的设备）。 */
export class NoopAuthenticator implements Authenticator {
  authenticate(title: string): Promise<void> {
    void title;
    return Promise.resolve();
  }
}

/** userIAM 实现：生物识别优先，PIN 兜底（系统弹窗控件形态）。 */
export class UserIamAuthenticator implements Authenticator {
  private readonly authTypes: userAuth.UserAuthType[];

  private constructor(authTypes: userAuth.UserAuthType[]) {
    this.authTypes = authTypes;
  }

  /** 按设备能力挑选凭据链：FACE/FINGERPRINT（ATL1）→ PIN（ATL1）。 */
  static create(): UserIamAuthenticator | undefined {
    const types: userAuth.UserAuthType[] = [];
    for (const biometric of [userAuth.UserAuthType.FACE, userAuth.UserAuthType.FINGERPRINT]) {
      if (UserIamAuthenticator.available(biometric)) {
        types.push(biometric);
      }
    }
    if (types.length === 0) {
      // 无生物硬件（典型：平板）→ 系统设备凭据 PIN。
      if (UserIamAuthenticator.available(userAuth.UserAuthType.PIN)) {
        types.push(userAuth.UserAuthType.PIN);
      }
    }
    if (types.length === 0) {
      return undefined;
    }
    return new UserIamAuthenticator(types);
  }

  private static available(type: userAuth.UserAuthType): boolean {
    try {
      userAuth.getAvailableStatus(type, userAuth.AuthTrustLevel.ATL1);
      return true;
    } catch (error) {
      return false;
    }
  }

  authenticate(title: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let instance: userAuth.UserAuthInstance;
      try {
        instance = userAuth.getUserAuthInstance(
          {
            challenge: new Uint8Array(0),
            authType: this.authTypes,
            authTrustLevel: userAuth.AuthTrustLevel.ATL1
          },
          { title: title });
      } catch (error) {
        reject(new Error(`auth unavailable: ${(error as BusinessError).message}`));
        return;
      }
      instance.on('result', {
        onResult: (result: userAuth.UserAuthResult) => {
          instance.off('result');
          if (result.result === userAuth.UserAuthResultCode.SUCCESS) {
            resolve();
          } else {
            reject(new Error(`auth failed: ${result.result}`));
          }
        }
      } as userAuth.IAuthCallback);
      try {
        instance.start();
      } catch (error) {
        instance.off('result');
        reject(new Error(`auth start failed: ${(error as BusinessError).message}`));
      }
    });
  }
}
