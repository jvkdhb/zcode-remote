import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export interface RecentSession {
  url: string;
  name: string;
  lastUsed: number;
}

const STORE_NAME: string = 'zcode_remote';
const KEY_RECENT: string = 'recent_sessions';
const MAX_RECENT: number = 5;

/**
 * 最近连接记录。只存本机 App 沙箱内的 Preferences，不打印完整 URL
 * （remote 链接里带会话参数，不应进日志）。
 */
export class SessionStore {
  private static async open(context: common.Context): Promise<preferences.Preferences> {
    const options: preferences.Options = { name: STORE_NAME };
    return preferences.getPreferences(context, options);
  }

  static async load(context: common.Context): Promise<RecentSession[]> {
    try {
      const store: preferences.Preferences = await SessionStore.open(context);
      const raw: preferences.ValueType = await store.get(KEY_RECENT, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return [];
      }
      const parsed: RecentSession[] = JSON.parse(raw) as RecentSession[];
      return parsed;
    } catch (e) {
      return [];
    }
  }

  static async save(context: common.Context, session: RecentSession): Promise<void> {
    try {
      const list: RecentSession[] = await SessionStore.load(context);
      const filtered: RecentSession[] = list.filter((item: RecentSession) => item.url !== session.url);
      filtered.unshift(session);
      const trimmed: RecentSession[] = filtered.slice(0, MAX_RECENT);
      const store: preferences.Preferences = await SessionStore.open(context);
      await store.put(KEY_RECENT, JSON.stringify(trimmed));
      await store.flush();
    } catch (e) {
      // 记录失败不影响本次连接
    }
  }

  static async remove(context: common.Context, url: string): Promise<void> {
    try {
      const list: RecentSession[] = await SessionStore.load(context);
      const filtered: RecentSession[] = list.filter((item: RecentSession) => item.url !== url);
      const store: preferences.Preferences = await SessionStore.open(context);
      await store.put(KEY_RECENT, JSON.stringify(filtered));
      await store.flush();
    } catch (e) {
      // 删除失败忽略
    }
  }
}
