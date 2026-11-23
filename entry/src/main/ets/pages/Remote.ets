import { common, Want } from '@kit.AbilityKit';
import { router, window, promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';

interface RemoteParams {
  remoteUrl?: string;
}

@Entry
@Component
struct Remote {
  @State remoteUrl: string = '';
  @State loading: boolean = true;
  @State progress: number = 0;
  @State errorText: string = '';
  @State authUrl: string = '';
  @State authVisible: boolean = false;
  @State downloadTip: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private authController: webview.WebviewController = new webview.WebviewController();
  private downloadDelegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate();
  // 页面主题机制：localStorage `zcode-theme`（zai-dark/zai-light/system），html 上挂 dark/theme-zai-* class。
  // 本壳不支持浅色：启动前强制 zai-dark，并用 MutationObserver 兜底——任何切到浅色的动作都被立即扳回深色。
  // SPA 路由切换会重建 DOM，所以顶栏隐藏/输入栏下移也做成页内常驻自愈（observer + 300ms 防抖）。
  private readonly themeBootJs: string = `(function(){
    try { localStorage.setItem('zcode-theme', 'zai-dark'); } catch (e) {}
    try {
      var st = document.createElement('style');
      st.textContent = '[data-share-theme-toggle]{display:none !important;}';
      (document.head || document.documentElement).appendChild(st);
      var html = document.documentElement;
      function enforceTheme() {
        if (!html.classList.contains('dark') || html.classList.contains('theme-zai-light')) {
          html.classList.add('dark');
          html.classList.remove('theme-zai-light');
          html.classList.add('theme-zai-dark');
          html.style.colorScheme = 'dark';
          try { localStorage.setItem('zcode-theme', 'zai-dark'); } catch (e) {}
        }
      }
      function fix() {
        try {
          if (document.body && !document.getElementById('zr-hide-topbar')) {
            var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), n;
            while ((n = w.nextNode())) {
              var t = (n.textContent || '').trim();
              if (t === '任务会话' || t === 'Task Sessions') {
                var e = n.parentElement;
                for (var j = 0; j < 6 && e; j++) {
                  var r = e.getBoundingClientRect();
                  if (r.top < 220 && r.height > 0 && r.height < 110 && r.width > 300) {
                    e.id = 'zr-hide-topbar';
                    e.style.setProperty('display', 'none', 'important');
                    break;
                  }
                  e = e.parentElement;
                }
                break;
              }
            }
          }
          var ce = document.querySelector('[contenteditable]');
          if (ce) {
            var card = ce;
            for (var i = 0; i < 10 && card; i++) {
              var cs = getComputedStyle(card);
              var radius = parseFloat(cs.borderTopLeftRadius) || 0;
              var bg = cs.backgroundColor;
              if (radius > 8 && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') { break; }
              card = card.parentElement;
            }
            if (card && card !== document.body) {
              // v5：卡片本身保形；把卡片之上的所有祖先（含 body/html）的下内边距/外边距清零
              var a = card.parentElement;
              for (var k = 0; k < 12 && a; k++) {
                if (getComputedStyle(a).paddingBottom !== '0px') { a.style.setProperty('padding-bottom', '0px', 'important'); }
                if (getComputedStyle(a).marginBottom !== '0px') { a.style.setProperty('margin-bottom', '0px', 'important'); }
                a = a.parentElement;
              }
              if (getComputedStyle(document.body).paddingBottom !== '0px') { document.body.style.setProperty('padding-bottom', '0px', 'important'); }
              var vp = window.visualViewport;
              var vh = vp ? Math.round(vp.height + vp.offsetTop) : window.innerHeight;
              var cr = card.getBoundingClientRect();
              var gap = vh - cr.bottom;
              if (gap > 0 && gap < 160) {
                card.style.transform = 'translateY(' + gap + 'px)';
                card.dataset.zrShifted = '1';
              }
            }
          }
        } catch (e) {}
      }
      var timer = null;
      new MutationObserver(function () {
        enforceTheme();
        if (timer) { return; }
        timer = setTimeout(function () { timer = null; fix(); }, 300);
      }).observe(html, { attributes: true, attributeFilter: ['class'], childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', fix);
      fix();
    } catch (e) {}
  })();`;

  aboutToAppear(): void {
    const params: RemoteParams = router.getParams() as RemoteParams;
    this.remoteUrl = params?.remoteUrl ?? '';
    if (this.remoteUrl.length === 0) {
      this.loading = false;
      this.errorText = '缺少远程链接，请返回重新扫码。';
    }
    this.setKeepScreenOn(true);
    this.setupDownload();
  }

  private setupDownload(): void {
    this.downloadDelegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      const name: string = item.getSuggestedFileName() || 'download';
      this.downloadTip = '准备保存：' + name;
      this.saveAs(name).then((path: string) => {
        if (path.length === 0) {
          item.cancel();
          this.downloadTip = '已取消下载';
          return;
        }
        try {
          item.start(path);
          this.downloadTip = '正在下载：' + name;
        } catch (e) {
          const err = e as BusinessError;
          item.cancel();
          this.downloadTip = `下载失败（${err.code}）`;
        }
      });
    });
    this.downloadDelegate.onDownloadFinish((item: webview.WebDownloadItem) => {
      this.downloadTip = '已保存：' + item.getSuggestedFileName();
      promptAction.showToast({ message: '已保存：' + item.getSuggestedFileName() });
    });
    this.downloadDelegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      this.downloadTip = '下载失败：' + item.getSuggestedFileName();
      promptAction.showToast({ message: '下载失败：' + item.getSuggestedFileName() });
    });
  }

  private async saveAs(suggested: string): Promise<string> {
    try {
      const context = getContext(this) as common.Context;
      const docPicker = new picker.DocumentViewPicker(context);
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [suggested];
      const uris = await docPicker.save(opts);
      if (uris.length === 0) {
        return '';
      }
      // DocumentViewPicker.save 返回的是可直接写入的 file:// uri；item.start 需要的就是路径或 uri
      return uris[0];
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, 'ZcodeRemote', 'saveAs failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  aboutToDisappear(): void {
    this.setKeepScreenOn(false);
  }

  onBackPress(): boolean {
    if (this.canGoBack()) {
      this.controller.backward();
      return true;
    }
    return false;
  }

  private async setKeepScreenOn(on: boolean): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this) as common.Context);
      await win.setWindowKeepScreenOn(on);
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'setKeepScreenOn failed: %{public}s', JSON.stringify(e));
    }
  }

  private canGoBack(): boolean {
    try {
      return this.controller.accessBackward();
    } catch (e) {
      return false;
    }
  }

  private reload(): void {
    this.errorText = '';
    this.loading = true;
    if (this.remoteUrl.length === 0) {
      this.loading = false;
      this.errorText = '缺少远程链接，请返回重新扫码。';
      return;
    }
    try {
      this.controller.loadUrl(this.remoteUrl);
    } catch (e) {
      this.loading = false;
      this.errorText = '无法重新加载，请返回后重试。';
    }
  }

  private applyPageTheme(): void {
    const css: string = ':root { color-scheme: dark !important; ' +
      '--color-terminal-bg: #0B1B33 !important; ' +
      '--color-background: #0B1B33 !important; ' +
      '--color-background-alt: #102A4A !important; ' +
      '--color-toast: #102A4A !important; ' +
      '--color-tooltip: #102A4A !important; ' +
      '--color-popover: #102A4A !important; ' +
      '--color-popover-foreground: #EAF2FF !important; ' +
      '--color-card: #102A4A !important; ' +
      '--color-panel: #102A4A !important; ' +
      '--color-surface: #15345C !important; ' +
      '--color-input: #0B1B33 !important; ' +
      '} ' +
      'html, body, #root { background-color: #0B1B33 !important; color-scheme: dark !important; } ' +
      '#root > div, .bg-background, .bg-terminal, [class*="bg-background"], [class*="bg-terminal"] { ' +
      'background-color: #0B1B33 !important; } ' +
      'header, [class*="header"], [class*="Header"], [class*="topbar"], [class*="top-bar"], ' +
      '[class*="sticky"], [class*="bg-card"], [class*="bg-surface"] { ' +
      'background-color: #0B1B33 !important; } ' +
      '[class*="bg-input"], [class*="bg-muted"], [class*="bg-panel"], ' +
      'input, textarea, [contenteditable] { ' +
      'background-color: #0B1B33 !important; color: #EAF2FF !important; } ' +
      'input::placeholder, textarea::placeholder { color: #7F9AC0 !important; }';
    try {
      this.controller.runJavaScript(`
        (function() {
          let s = document.getElementById('zcode-remote-theme');
          if (!s) {
            s = document.createElement('style');
            s.id = 'zcode-remote-theme';
            document.head.appendChild(s);
          }
          s.textContent = ${JSON.stringify(css)};
        })();
      `);
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'applyPageTheme failed: %{public}s', JSON.stringify(e));
    }
  }

  private close(): void {
    router.back();
  }

  private async openInBrowser(): Promise<void> {
    if (this.remoteUrl.length === 0) {
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: this.remoteUrl
      };
      await context.startAbility(want);
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'openInBrowser failed: %{public}s', JSON.stringify(e));
    }
  }

  @Builder
  ErrorView() {
    Column({ space: 12 }) {
      Text('页面加载失败')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#EAF2FF')
      Text(this.errorText)
        .fontSize(13)
        .fontColor('#B9CDE6')
        .textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('重试')
          .onClick(() => {
            this.reload();
          })
        Button('返回')
          .backgroundColor('#1B3A60')
          .fontColor('#A9C2DE')
          .onClick(() => {
            this.close();
          })
      }
    }
    .width('86%')
    .padding(24)
    .borderRadius(16)
    .backgroundColor('#102A4A')
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Button('‹')
          .fontSize(22)
          .height(36)
          .width(40)
          .backgroundColor(Color.Transparent)
          .fontColor('#EAF2FF')
          .onClick(() => {
            if (this.canGoBack()) {
              this.controller.backward();
            } else {
              this.close();
            }
          })
        Text('主页')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF2FF')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('刷新')
          .fontSize(13)
          .height(32)
          .backgroundColor(Color.Transparent)
          .fontColor('#EAF2FF')
          .onClick(() => {
            this.reload();
          })
        Button('浏览器')
          .fontSize(13)
          .height(32)
          .backgroundColor(Color.Transparent)
          .fontColor('#EAF2FF')
          .onClick(() => {
            this.openInBrowser();
          })
        Button('关闭')
          .fontSize(13)
          .height(32)
          .backgroundColor(Color.Transparent)
          .fontColor('#EAF2FF')
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })
      .backgroundColor('#0B1B33')

      if (this.downloadTip.length > 0) {
        Text(this.downloadTip)
          .fontSize(11)
          .fontColor('#B9CDE6')
          .backgroundColor('#102A4A')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .borderRadius(10)
          .margin({ top: 4 })
      }

      if (this.loading && this.errorText.length === 0) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color('#5B8DEF')
          .backgroundColor('#1B3A60')
      }

      Stack({ alignContent: Alignment.Center }) {
        if (this.remoteUrl.length > 0) {
          Web({ src: this.remoteUrl, controller: this.controller })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .zoomAccess(false)
            .javaScriptOnDocumentStart([{ script: this.themeBootJs, scriptRules: ['*'] }])
            .onControllerAttached(() => {
              try {
                this.controller.setDownloadDelegate(this.downloadDelegate);
              } catch (e) {
                hilog.warn(0x0000, 'ZcodeRemote', 'setDownloadDelegate failed: %{public}s', JSON.stringify(e));
              }
            })
            .onPageBegin(() => {
              this.loading = true;
            })
            .onPageEnd(() => {
              this.loading = false;
              this.applyPageTheme();
            })
            .onProgressChange((event) => {
              this.progress = event.newProgress;
            })
            .onErrorReceive((event) => {
              if (!event.request.isMainFrame()) {
                return;
              }
              this.loading = false;
              this.errorText = `网络错误：${event.error.getErrorInfo()}`;
            })
            .onHttpErrorReceive((event) => {
              if (!event.request.isMainFrame()) {
                hilog.warn(0x0000, 'ZcodeRemote', 'subresource HTTP %{public}d: %{public}s',
                  event.response.getResponseCode(), event.request.getRequestUrl());
                return;
              }
              this.loading = false;
              this.errorText = `HTTP 错误：${event.response.getResponseCode()}`;
            })
            .onSslErrorEventReceive((event) => {
              event.handler.handleCancel();
              this.loading = false;
              this.errorText = '证书校验失败，已阻止连接。';
            })
            .onPermissionRequest((event) => {
              event.request.deny();
            })
            .backgroundColor('#0B1B33')
            .multiWindowAccess(true)
            .onWindowNew((event) => {
              hilog.info(0x0000, 'ZcodeRemote', 'onWindowNew url=%{public}s alert=%{public}s',
                event.targetUrl, String(event.isAlert));
              this.authUrl = event.targetUrl;
              this.authVisible = true;
              event.handler.setWebController(this.authController);
            })
            .onWindowExit(() => {
              hilog.info(0x0000, 'ZcodeRemote', 'auth window exited');
              this.authVisible = false;
              this.authUrl = '';
              this.reload();
            })
            .width('100%')
            .height('100%')
        }

        if (this.loading && this.errorText.length === 0) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(36)
              .height(36)
            Text('正在加载远程工作区…')
              .fontSize(13)
              .fontColor('#B9CDE6')
          }
          .padding(24)
          .backgroundColor('#102A4A')
          .borderRadius(12)
        }

        if (this.errorText.length > 0) {
          this.ErrorView()
        }

        if (this.authVisible) {
          Column() {
            Row() {
              Text('登录授权')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#EAF2FF')
                .layoutWeight(1)
              Button('关闭')
                .height(32)
                .fontSize(13)
                .backgroundColor('#1B3A60')
                .fontColor('#A9C2DE')
                .onClick(() => {
                  this.authVisible = false;
                  this.authUrl = '';
                })
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 8 })
            .backgroundColor('#0B1B33')

            Web({ src: this.authUrl, controller: this.authController })
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(false)
              .zoomAccess(false)
              .onWindowExit(() => {
                this.authVisible = false;
                this.authUrl = '';
                this.reload();
              })
              .width('100%')
              .layoutWeight(1)
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#0B1B33')
        }
      }
      .layoutWeight(1)
      .width('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1B33')
  }
}
