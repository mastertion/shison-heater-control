/**
 * 隐私政策同意状态 (AGC 上架审核合规)
 *
 * 华为《审核指南》7.5 / 7.17 要求:
 *   1. 应用首次启动须以显著方式提示用户阅读隐私政策;
 *   2. 用户同意隐私政策之前, 不得申请任何权限;
 *   3. 权限须在用户主动点击对应业务功能时才申请, 不得提前弹窗。
 *
 * 本模块复用 DeviceStore 的 sicn_pref 偏好库, 只持久化一个布尔标记。
 * 默认 false (未同意), 保证新装/清数据后首次启动一定弹隐私政策弹窗。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'sicn_pref';
const KEY_AGREED: string = 'privacy_agreed_v1';

export class PrivacyConsent {
  /** 是否已同意隐私政策 */
  static async isAgreed(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      const v: boolean = (await pref.get(KEY_AGREED, false)) as boolean;
      return v === true;
    } catch (e) {
      return false;
    }
  }

  /** 记录用户已同意 (幂等) */
  static async agree(context: common.UIAbilityContext): Promise<void> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      await pref.put(KEY_AGREED, true);
      await pref.flush();
    } catch (e) {
      // 持久化失败不阻断本次会话, 下次启动会再次提示
    }
  }

  /** 撤回同意 (供设置项/测试使用) */
  static async revoke(context: common.UIAbilityContext): Promise<void> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      await pref.put(KEY_AGREED, false);
      await pref.flush();
    } catch (e) {
      // 忽略
    }
  }
}
