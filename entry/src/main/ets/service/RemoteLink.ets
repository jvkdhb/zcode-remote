import { url } from '@kit.ArkTS';

const REMOTE_HOST: string = 'zcode.z.ai';
const REMOTE_PATH_PREFIX: string = '/remote/';

export interface ParsedRemoteLink {
  url: string;
  sid: string;
  mid: string;
  name: string;
}

/**
 * 只接受 https://zcode.z.ai/remote/... 且带 sid/mid 的远程链接，
 * 避免扫码内容被替换成任意钓鱼地址。
 */
export class RemoteLink {
  static parse(raw: string): ParsedRemoteLink | null {
    const text: string = raw.trim();
    if (text.length === 0) {
      return null;
    }

    let parsed: url.URL;
    try {
      parsed = new url.URL(text);
    } catch (e) {
      return null;
    }

    if (parsed.protocol !== 'https:') {
      return null;
    }
    if (parsed.hostname !== REMOTE_HOST) {
      return null;
    }
    if (!parsed.pathname.startsWith(REMOTE_PATH_PREFIX)) {
      return null;
    }

    const sid: string = parsed.searchParams.get('sid') ?? '';
    const mid: string = parsed.searchParams.get('mid') ?? '';
    if (sid.length === 0 || mid.length === 0) {
      return null;
    }

    return {
      url: parsed.toString(),
      sid: sid,
      mid: mid,
      name: parsed.searchParams.get('name') ?? REMOTE_HOST
    };
  }

  static isRemoteUrl(value: string): boolean {
    return RemoteLink.parse(value) !== null;
  }
}
