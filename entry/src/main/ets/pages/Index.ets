import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { ParsedRemoteLink, RemoteLink } from '../service/RemoteLink';
import { RecentSession, SessionStore } from '../service/SessionStore';

const EMBEDDED_HAP_RAWFILE: string = 'ZcodeRemote-v5.hap';
const EMBEDDED_HAP_NAME: string = 'ZcodeRemote-v5.hap';

@Entry
@Component
struct Index {
  @State linkInput: string = '';
  @State recent: RecentSession[] = [];
  @State scanning: boolean = false;
  @State exporting: boolean = false;

  aboutToAppear(): void {
    this.refreshRecent();
  }

  private async refreshRecent(): Promise<void> {
    this.recent = await SessionStore.load(getContext(this) as common.Context);
  }

  private async scan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableAlbum: true
      });
      this.connect(result.originalValue);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED) {
        promptAction.showToast({ message: `扫码失败（${err.code}）` });
      }
    } finally {
      this.scanning = false;
    }
  }

  private connect(raw: string): void {
    const link: ParsedRemoteLink | null = RemoteLink.parse(raw);
    if (link === null) {
      promptAction.showToast({ message: '链接无效：只支持 https://zcode.z.ai/remote/ 开头的地址' });
      return;
    }
    const session: RecentSession = {
      url: link.url,
      name: link.name,
      lastUsed: Date.now()
    };
    SessionStore.save(getContext(this) as common.Context, session);
    this.refreshRecent();
    router.pushUrl({
      url: 'pages/Remote',
      params: { remoteUrl: link.url }
    });
  }

  private openRecent(session: RecentSession): void {
    this.connect(session.url);
  }

  private removeRecent(session: RecentSession): void {
    SessionStore.remove(getContext(this) as common.Context, session.url);
    this.refreshRecent();
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  private async exportHap(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const context = getContext(this) as common.Context;
      const docPicker = new picker.DocumentViewPicker(context);
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [EMBEDDED_HAP_NAME];
      const uris = await docPicker.save(opts);
      if (uris.length === 0) {
        return;
      }
      const srcFile = await context.resourceManager.getRawFileDescriptor(EMBEDDED_HAP_RAWFILE);
      const dst = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.copyFile(srcFile.fd, dst.fd);
      fs.closeSync(dst);
      promptAction.showToast({ message: '已保存 ' + EMBEDDED_HAP_NAME });
    } catch (e) {
      const err = e as BusinessError;
      promptAction.showToast({ message: `保存失败（${err.code}）` });
    } finally {
      this.exporting = false;
    }
  }

  build() {
    Column({ space: 14 }) {
      Column({ space: 4 }) {
        Text('ZCode 遥控')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F7FF')
        Text('扫码连接电脑端 ZCode，查看工作状态并下指令')
          .fontSize(13)
          .fontColor('#8FA9C9')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Button(this.scanning ? '正在打开扫码…' : '扫码连接电脑')
        .width('100%')
        .height(48)
        .backgroundColor('#3F74E0')
        .fontColor('#FFFFFF')
        .enabled(!this.scanning)
        .onClick(() => {
          this.scan();
        })

      Button(this.exporting ? '正在保存…' : '保存安装包（测试用）')
        .width('100%')
        .height(44)
        .backgroundColor('#1B3A60')
        .fontColor('#A9C2DE')
        .enabled(!this.exporting)
        .onClick(() => {
          this.exportHap();
        })

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '粘贴 zcode.z.ai/remote/... 链接', text: this.linkInput })
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#15345C')
            .fontColor('#EAF2FF')
            .placeholderColor('#7F9AC0')
            .caretColor('#5B8DEF')
            .borderRadius(14)
            .onChange((value: string) => {
              this.linkInput = value;
            })
          Button('连接')
            .height(44)
            .backgroundColor('#3F74E0')
            .fontColor('#FFFFFF')
            .opacity(this.linkInput.trim().length > 0 ? 1 : 0.45)
            .enabled(this.linkInput.trim().length > 0)
            .onClick(() => {
              this.connect(this.linkInput);
            })
        }
        .width('100%')

        Text('也可以长按输入框，把电脑上复制的链接粘贴进来')
          .fontSize(11)
          .fontColor('#7F9AC0')
          .width('100%')
      }

      Row() {
        Text('最近连接')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF2FF')
        Blank()
        Text(`${this.recent.length}/5`)
          .fontSize(12)
          .fontColor('#7F9AC0')
      }
      .width('100%')
      .margin({ top: 6 })

      if (this.recent.length === 0) {
        Column({ space: 4 }) {
          Text('还没有连接记录')
            .fontSize(14)
            .fontColor('#AFC6E2')
          Text('先在电脑端打开远程控制面板，再扫它的二维码')
            .fontSize(12)
            .fontColor('#7F9AC0')
        }
        .width('100%')
        .padding(24)
        .borderRadius(12)
        .backgroundColor('#102A4A')
      } else {
        List({ space: 8 }) {
          ForEach(this.recent, (item: RecentSession) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 4 }) {
                  Text(item.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#EAF2FF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.formatTime(item.lastUsed))
                    .fontSize(12)
                    .fontColor('#7F9AC0')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Button('连接')
                  .height(32)
                  .fontSize(13)
                  .backgroundColor('#3F74E0')
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.openRecent(item);
                  })
                Button('删')
                  .height(32)
                  .fontSize(13)
                  .backgroundColor('#1B3A60')
                  .fontColor('#A9C2DE')
                  .onClick(() => {
                    this.removeRecent(item);
                  })
              }
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .backgroundColor('#102A4A')
            }
          }, (item: RecentSession) => item.url)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .padding(20)
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1B33')
  }
}
