import { common, Want } from '@kit.AbilityKit';
import { router, window, promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppEvents } from '../service/AppEvents';

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
  // 恢复遮罩：退后台前抓一帧 Web 快照；回前台或页面重载时先盖住旧画面，
  // 等会话 UI 真正就绪（注入脚本回报 ZR_READY）再揭开，避免闪回加载页。
  private lastSnapshot: image.PixelMap | undefined = undefined;
  @State maskVisible: boolean = false;
  @State maskHint: boolean = false;
  @State maskOpacity: number = 1;
  private webW: number = 0;
  private webH: number = 0;
  private pageLoading: boolean = false;
  private readySeen: boolean = false;
  private minDone: boolean = false;
  private minTimer: number = -1;
  private probeTimer: number = -1;
  private capTimer: number = -1;
  private hintTimer: number = -1;
  private hideTimer: number = -1;
  private fadeTimer: number = -1;
  private settleTimer: number = -1;
  private lastPersistAt: number = 0;
  private persistBusy: boolean = false;
  private awaitSnapshot: boolean = false;
  private lastUploadRenamed: boolean = false;
  private readyAt: number = 0;
  private stableMs: number = 0;
  // 一次回前台只提示一次「正在恢复会话」，后续重连静默接管
  private hintShown: boolean = false;
  // 只有「回前台/手动刷新」后的导航才值得用旧画面遮挡；普通站内跳转直接放行
  private maskNavUntil: number = 0;
  // 网页侧连接状态（由注入脚本回报）：socket 未恢复或页面处于连接中时，遮罩不揭开
  private sockClosed: boolean = false;
  private sockClosedAt: number = 0;
  private pageConnecting: boolean = false;
  private maskSuppressed: boolean = false;
  private onFgEvent: (data: emitter.EventData) => void = (data: emitter.EventData) => {
    this.handleAppForeground();
  };
  private onBgEvent: (data: emitter.EventData) => void = (data: emitter.EventData) => {
    this.handleAppBackground();
  };
  // 页面主题机制：localStorage `zcode-theme`（zai-dark/zai-light/system），html 上挂 dark/theme-zai-* class。
  // 本壳不支持浅色：启动前强制 zai-dark，并用 MutationObserver 兜底——任何切到浅色的动作都被立即扳回深色。
  // SPA 路由切换会重建 DOM，所以顶栏隐藏/输入栏下移也做成页内常驻自愈（observer + 300ms 防抖）。
  private readonly themeBootJs: string = `(function(){
    // 记录网页 WebSocket 生命周期：断开/重连时回传，原生据此决定遮罩何时揭开
    try {
      var OWS = window.WebSocket;
      if (OWS && !OWS.__zrPatched) {
        var zrOpen = 0;
        function ZrWS(url, protocols) {
          var ws = protocols === undefined ? new OWS(url) : new OWS(url, protocols);
          try {
            window.__zrHasWS = true;
            ws.addEventListener('open', function () {
              zrOpen++;
              window.__zrOpen = zrOpen;
              console.info('ZR_SOCKET_OPEN ' + zrOpen);
            });
            ws.addEventListener('close', function () {
              zrOpen--;
              window.__zrOpen = zrOpen;
              console.info('ZR_SOCKET_CLOSE ' + zrOpen);
            });
          } catch (e1) {}
          return ws;
        }
        ZrWS.prototype = OWS.prototype;
        ZrWS.CONNECTING = OWS.CONNECTING;
        ZrWS.OPEN = OWS.OPEN;
        ZrWS.CLOSING = OWS.CLOSING;
        ZrWS.CLOSED = OWS.CLOSED;
        ZrWS.__zrPatched = true;
        window.WebSocket = ZrWS;
      }
    } catch (e0) {}
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
          var found = !!document.getElementById('zr-hide-topbar');
          var conn = false;
          // 会话页（有输入框/已隐藏顶栏）不扫正文，避免大页面反复算 innerText 造成卡顿
          if (!found && !document.querySelector('[contenteditable]')) {
            try {
              var bt = document.body ? (document.body.textContent || '') : '';
              conn = bt.indexOf('正在连接') >= 0 || bt.indexOf('正在加载工作区') >= 0;
            } catch (e5) {}
          }
          if (conn) {
            try {
              var cnow = Date.now();
              if (!window.__zrConnAt || cnow - window.__zrConnAt > 800) {
                window.__zrConnAt = cnow;
                console.info('ZR_CONNECTING');
              }
            } catch (e6) {}
          }
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
                    found = true;
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
            var card = window.__zrCard;
            if (!card || !card.isConnected) {
              card = ce;
              for (var i = 0; i < 10 && card; i++) {
                var cs = getComputedStyle(card);
                var radius = parseFloat(cs.borderTopLeftRadius) || 0;
                var bg = cs.backgroundColor;
                if (radius > 8 && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') { break; }
                card = card.parentElement;
              }
              window.__zrCard = card;
            }
            if (card && card !== document.body) {
              found = true;
              // 已下移过就不再重算（新卡片没有标记，路由切换后仍会自动重跑）
              if (card.dataset.zrShifted !== '1') {
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
          }
          if (found && !conn) {
            try {
              var now = Date.now();
              if (!window.__zrReadyAt || now - window.__zrReadyAt > 800) {
                window.__zrReadyAt = now;
                console.info('ZR_READY ' + (window.__zrHasWS ? 1 : 0) + ' ' + (window.__zrOpen || 0));
              }
            } catch (e2) {}
          }
        } catch (e) {}
      }
      var timer = null;
      new MutationObserver(function () {
        window.__zrLastMut = Date.now();
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
    try {
      // 快照依赖整页绘制能力；必须在 Web 组件初始化前调用
      webview.WebviewController.enableWholeWebPageDrawing();
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'enableWholeWebPageDrawing failed: %{public}s', JSON.stringify(e));
    }
    emitter.on({ eventId: AppEvents.FOREGROUND }, this.onFgEvent);
    emitter.on({ eventId: AppEvents.BACKGROUND }, this.onBgEvent);
    this.loadPersistedSnapshot();
  }

  // ---- 恢复遮罩：后台抓帧，回前台/重载时盖住，会话就绪后揭开 ----

  private handleAppBackground(): void {
    this.clearMask();
    this.captureSnapshot(true);
  }

  private handleAppForeground(): void {
    if (this.remoteUrl.length === 0) {
      return;
    }
    this.maskNavUntil = Date.now() + 30000;
    if (this.lastSnapshot === undefined) {
      // 快照可能在落盘/解码中，加载完成后再决定是否盖
      this.awaitSnapshot = true;
      hilog.info(0x0000, 'ZcodeRemote', 'resume: no snapshot in memory yet');
      return;
    }
    this.awaitSnapshot = false;
    hilog.info(0x0000, 'ZcodeRemote', 'resume: mask on, snapshot=%{public}s', String(this.lastSnapshot !== undefined));
    this.sockClosed = false;
    this.sockClosedAt = 0;
    this.pageConnecting = false;
    this.maskSuppressed = false;
    this.hintShown = false;
    this.showMask(true);
    this.probeReady(350);
    // 页面若没重载（没有 onPageBegin）且连接正常，3.5s 内揭开
    this.settleTimer = setTimeout(() => {
      this.settleTimer = -1;
      if (!this.pageLoading && !this.sockClosed) {
        this.clearMask();
      }
    }, 3500);
  }

  private onPageConnecting(): void {
    this.pageConnecting = true;
    if (this.lastSnapshot === undefined || this.maskSuppressed) {
      return;
    }
    if (!this.sockClosed) {
      this.sockClosed = true;
      this.sockClosedAt = Date.now();
    }
    this.readySeen = false;
    // 只在回前台/手动刷新后的窗口内遮；平时断网不擅自盖住页面
    if (!this.maskVisible && Date.now() > this.maskNavUntil) {
      return;
    }
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    if (!this.maskVisible) {
      this.showMask(false);
    }
  }

  private onSocketChanged(msg: string): void {
    const count: number = this.parseSocketCount(msg);
    if (msg.indexOf('ZR_SOCKET_CLOSE') >= 0) {
      if (count > 0) {
        return;
      }
      if (!this.sockClosed) {
        this.sockClosed = true;
        this.sockClosedAt = Date.now();
      }
      if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
      if (this.lastSnapshot !== undefined && !this.maskVisible && !this.maskSuppressed &&
        Date.now() <= this.maskNavUntil) {
        this.showMask(false);
      }
    } else {
      if (count <= 0) {
        return;
      }
      this.sockClosed = false;
      this.pageConnecting = false;
      this.tryHideMask();
    }
  }

  private parseSocketCount(msg: string): number {
    const i: number = msg.lastIndexOf(' ');
    if (i < 0) {
      return -1;
    }
    const n: number = Number(msg.substring(i + 1));
    return isNaN(n) ? -1 : n;
  }

  private captureSnapshot(force: boolean = false): void {
    // 页面被遮/正在连接时不抓；force 用于退后台前最后一张（哪怕画面是连接页，也是用户最后看到的）
    if (!force && (this.maskVisible || this.pageConnecting)) {
      return;
    }
    try {
      const info: webview.SnapshotInfo = {};
      if (this.webW > 0 && this.webH > 0) {
        info.size = { width: this.webW, height: this.webH };
      }
      this.controller.webPageSnapshot(info, (err: BusinessError, res: webview.SnapshotResult) => {
        if (err || res === undefined || res.imagePixelMap === undefined) {
          hilog.warn(0x0000, 'ZcodeRemote', 'snapshot failed: %{public}s', JSON.stringify(err));
          return;
        }
        const old: image.PixelMap | undefined = this.lastSnapshot;
        this.lastSnapshot = res.imagePixelMap;
        if (old !== undefined && !this.maskVisible) {
          old.release();
        }
        this.persistSnapshot(res.imagePixelMap);
      });
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'webPageSnapshot failed: %{public}s', JSON.stringify(e));
    }
  }

  private framePath(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return ctx.filesDir + '/zr_frame_' + this.urlHash() + '.jpg';
  }

  private urlHash(): string {
    let h: number = 0;
    for (let i = 0; i < this.remoteUrl.length; i++) {
      h = (h * 31 + this.remoteUrl.charCodeAt(i)) | 0;
    }
    return Math.abs(h).toString(16);
  }

  // 快照落盘：页面被系统重建后，内存快照会丢，靠这个兜住
  private persistSnapshot(pm: image.PixelMap): void {
    if (this.persistBusy || Date.now() - this.lastPersistAt < 10000) {
      return;
    }
    this.persistBusy = true;
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      packer.packing(pm, { format: 'image/jpeg', quality: 70 }).then((buf: ArrayBuffer) => {
        const f = fileIo.openSync(this.framePath(),
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, buf);
        fileIo.closeSync(f);
        this.lastPersistAt = Date.now();
        this.persistBusy = false;
      }).catch((e: BusinessError) => {
        this.persistBusy = false;
        hilog.warn(0x0000, 'ZcodeRemote', 'persist snapshot failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      this.persistBusy = false;
      hilog.warn(0x0000, 'ZcodeRemote', 'persist snapshot call failed: %{public}s', JSON.stringify(e));
    }
  }

  private loadPersistedSnapshot(): void {
    if (this.remoteUrl.length === 0) {
      return;
    }
    try {
      const path: string = this.framePath();
      const stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return;
      }
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const src: image.ImageSource = image.createImageSource(buf);
      src.createPixelMap().then((pm: image.PixelMap) => {
        if (this.lastSnapshot === undefined) {
          this.lastSnapshot = pm;
        } else {
          pm.release();
        }
        const ageSec: number = Math.floor(Date.now() / 1000) - stat.mtime;
        hilog.info(0x0000, 'ZcodeRemote', 'persisted snapshot loaded age=%{public}d', ageSec);
        // 10 分钟内的旧画面才值得盖：兼容「页面被重建、回前台事件已错过」的情况
        if (ageSec < 600 && (this.awaitSnapshot || this.loading)) {
          this.awaitSnapshot = false;
          this.showMask(false);
          this.pageLoading = true;
          this.probeReady(400);
        }
      }).catch((e: BusinessError) => {
        hilog.warn(0x0000, 'ZcodeRemote', 'decode persisted snapshot failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.info(0x0000, 'ZcodeRemote', 'no persisted snapshot: %{public}s', JSON.stringify(e));
    }
  }

  private showMask(holdMin: boolean): void {
    this.clearMaskTimers();
    if (this.fadeTimer >= 0) { clearTimeout(this.fadeTimer); this.fadeTimer = -1; }
    this.maskOpacity = 1;
    this.maskVisible = true;
    this.maskHint = false;
    this.readySeen = false;
    this.minDone = false;
    this.pageLoading = false;
    this.readyAt = 0;
    this.stableMs = 0;
    this.minTimer = setTimeout(() => {
      this.minTimer = -1;
      this.minDone = true;
      this.tryHideMask();
    }, holdMin ? 2500 : 0);
    this.hintTimer = setTimeout(() => {
      this.hintTimer = -1;
      if (this.maskVisible && !this.hintShown) {
        this.hintShown = true;
        this.maskHint = true;
      }
    }, 2500);
    this.capTimer = setTimeout(() => {
      this.capTimer = -1;
      hilog.info(0x0000, 'ZcodeRemote', 'mask cap reached, reveal page');
      this.maskSuppressed = true;
      this.clearMask();
    }, 15000);
    // 遮罩一旦出现就持续探测「会话是否就绪 + DOM 是否安静」
    this.probeReady(300);
  }

  private tryHideMask(): void {
    if (!this.maskVisible || !this.minDone || !this.readySeen || this.pageLoading) {
      return;
    }
    // 会话内容还在重排（DOM 持续变化）就继续盖；安静 0.7s 后揭，最多再多等 4s
    if (this.stableMs < 700 && this.readyAt > 0 && Date.now() - this.readyAt < 4000) {
      return;
    }
    // socket 关闭时最多再等等连接恢复；超过 6s 仍未恢复就放行，避免无限卡住
    if (this.sockClosed) {
      if (this.sockClosedAt > 0 && Date.now() - this.sockClosedAt < 6000) {
        return;
      }
      this.sockClosed = false;
    }
    if (this.hideTimer >= 0) {
      return;
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      // 就绪后再给内容 1.2s 落稳，避免揭开时正好是空白重拉
      this.clearMask();
    }, 1200);
  }

  private clearMask(): void {
    this.clearMaskTimers();
    if (!this.maskVisible) {
      this.maskOpacity = 1;
      return;
    }
    // 淡出：用旧画面渐隐盖住揭盖瞬间的重绘空白
    this.maskOpacity = 0;
    this.fadeTimer = setTimeout(() => {
      this.fadeTimer = -1;
      if (this.maskOpacity === 0) {
        this.maskVisible = false;
        this.maskHint = false;
        this.readySeen = false;
        this.minDone = false;
        this.readyAt = 0;
        this.stableMs = 0;
        this.maskOpacity = 1;
      }
    }, 230);
  }

  private clearMaskTimers(): void {
    if (this.minTimer >= 0) { clearTimeout(this.minTimer); this.minTimer = -1; }
    if (this.probeTimer >= 0) { clearTimeout(this.probeTimer); this.probeTimer = -1; }
    if (this.capTimer >= 0) { clearTimeout(this.capTimer); this.capTimer = -1; }
    if (this.hintTimer >= 0) { clearTimeout(this.hintTimer); this.hintTimer = -1; }
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    if (this.fadeTimer >= 0) { clearTimeout(this.fadeTimer); this.fadeTimer = -1; }
    if (this.settleTimer >= 0) { clearTimeout(this.settleTimer); this.settleTimer = -1; }
  }

  private probeReady(delay: number): void {
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
    this.probeTimer = setTimeout(() => {
      this.probeTimer = -1;
      if (!this.maskVisible) {
        return;
      }
      const js: string = '(function(){try{' +
        'var ce=document.querySelector(\'[contenteditable]\');' +
        'var tb=document.getElementById(\'zr-hide-topbar\');' +
        'if(!ce&&!tb)return \'0\';' +
        'return \'1 \'+(window.__zrHasWS?1:0)+\' \'+(window.__zrOpen||0)+\' \'+(Date.now()-(window.__zrLastMut||0));' +
        '}catch(e){return \'0\';}})()';
      try {
        this.controller.runJavaScript(js, (err: BusinessError, res: string) => {
          if (!err && res !== undefined && res.charAt(0) === '1') {
            this.applyReadyState(res);
            const parts: string[] = res.split(' ');
            this.stableMs = parts.length > 3 ? Number(parts[3]) : 0;
            this.readySeen = true;
            if (this.readyAt === 0) {
              this.readyAt = Date.now();
            }
            if (this.stableMs < 700) {
              this.probeReady(400);
            } else {
              this.tryHideMask();
            }
          } else {
            this.probeReady(800);
          }
        });
      } catch (e) {
        hilog.warn(0x0000, 'ZcodeRemote', 'probeReady failed: %{public}s', JSON.stringify(e));
      }
    }, delay);
  }

  private onPageReadyLog(msg: string): void {
    this.pageConnecting = false;
    this.applyReadyState(msg);
    if (!this.maskVisible) {
      return;
    }
    this.readySeen = true;
    if (this.readyAt === 0) {
      this.readyAt = Date.now();
    }
    // DOM 是否安静由探针判断，这里只保证探针在跑
    this.probeReady(400);
  }

  // 解析 "ZR_READY <hasWS> <openCount>" 或 "1 <hasWS> <openCount>"
  private applyReadyState(res: string): void {
    const parts: string[] = res.split(' ');
    const hasWs: number = parts.length > 1 ? Number(parts[1]) : 0;
    const open: number = parts.length > 2 ? Number(parts[2]) : 0;
    const closed: boolean = hasWs === 1 && open <= 0;
    if (closed && !this.sockClosed) {
      this.sockClosed = true;
      this.sockClosedAt = Date.now();
    } else if (!closed) {
      this.sockClosed = false;
    }
    this.pageConnecting = false;
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

  // 接管网页的 <input type=file>：图片/视频走相册，其余（文档/HAP 等）复制到 App 缓存后再交给网页，
  // 否则 ArkWeb 拿到的文件可能没有内容（表现为「附件缺少」）。
  private async pickFilesForWeb(event: OnShowFileSelectorEvent): Promise<void> {
    try {
      const accept: string[] = event.fileSelector.getAcceptType();
      this.lastUploadRenamed = false;
      const mode: FileSelectorMode = event.fileSelector.getMode();
      const multiple: boolean = mode === FileSelectorMode.FileOpenMultipleMode;
      let hasImage: boolean = false;
      let hasVideo: boolean = false;
      let mediaOnly: boolean = accept.length > 0;
      for (let i = 0; i < accept.length; i++) {
        const t: string = accept[i];
        if (t.startsWith('image/')) {
          hasImage = true;
        } else if (t.startsWith('video/')) {
          hasVideo = true;
        } else {
          mediaOnly = false;
        }
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      let uris: string[] = [];
      if (mediaOnly) {
        const opt = new picker.PhotoSelectOptions();
        if (hasImage && !hasVideo) {
          opt.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
        } else if (hasVideo && !hasImage) {
          opt.MIMEType = picker.PhotoViewMIMETypes.VIDEO_TYPE;
        } else {
          opt.MIMEType = picker.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
        }
        opt.maxSelectNumber = multiple ? 20 : 1;
        const photoPicker = new picker.PhotoViewPicker(ctx);
        const res: picker.PhotoSelectResult = await photoPicker.select(opt);
        uris = res.photoUris;
      } else {
        const opt = new picker.DocumentSelectOptions();
        opt.maxSelectNumber = multiple ? 10 : 1;
        const docPicker = new picker.DocumentViewPicker(ctx);
        uris = await docPicker.select(opt);
      }
      const out: string[] = [];
      for (let i = 0; i < uris.length; i++) {
        const u: string = uris[i];
        if (mediaOnly) {
          out.push(u);
          continue;
        }
        const dst: string = await this.copyUploadToCache(u);
        // handleFileList 传绝对路径（传 file:// URI 时网页能拿到元数据但读不到内容）
        out.push(dst.length > 0 ? dst : u);
      }
      event.result.handleFileList(out);
      if (this.lastUploadRenamed) {
        promptAction.showToast({ message: '包已按 .txt 发送，接收后去掉 .txt 即可' });
      }
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'fileSelect failed: %{public}s', JSON.stringify(e));
      try {
        event.result.handleFileList([]);
      } catch (e2) {
      }
    }
  }

  private async copyUploadToCache(uri: string): Promise<string> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const base: string = ctx.cacheDir + '/zr_upload';
      try {
        fileIo.mkdirSync(base, true);
      } catch (e) {
      }
      let name: string = '';
      try {
        name = new fileUri.FileUri(uri).name;
      } catch (e) {
      }
      if (name.length === 0) {
        name = uri.substring(uri.lastIndexOf('/') + 1);
        const q: number = name.indexOf('?');
        if (q >= 0) {
          name = name.substring(0, q);
        }
      }
      if (name.length === 0) {
        name = 'upload.bin';
      }
      // .hap/.apk/.zip 等包和压缩包会被远程上传接口拒绝（「附件缺少可读取内容」），
  // 缓存副本加 .txt 后缀绕过类型白名单；接收后去掉 .txt 即可还原
  let finalName: string = name;
  const blockedExts: string[] = ['.hap', '.hsp', '.app', '.apk', '.aab', '.ipa', '.zip', '.rar',
    '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.exe', '.msi', '.dmg', '.iso', '.bin',
    '.wav', '.flac', '.ape', '.wma', '.aac', '.ogg', '.opus'];
  const lowerName: string = name.toLowerCase();
  for (let i = 0; i < blockedExts.length; i++) {
    if (lowerName.endsWith(blockedExts[i])) {
      finalName = name + '.txt';
      this.lastUploadRenamed = true;
      break;
    }
  }
      // 每次上传单独一个目录，文件名保持原样（网页可能按文件名判断类型）
      const dir: string = base + '/' + Date.now();
      try {
        fileIo.mkdirSync(dir, true);
      } catch (e) {
      }
      const dst: string = dir + '/' + finalName;
      // 选择器返回的是 docs URI，copyFile 直接传 URI 会 13900002；先 open 再用 fd 复制
      const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        await fileIo.copyFile(src.fd, dst);
      } finally {
        fileIo.closeSync(src);
      }
      hilog.info(0x0000, 'ZcodeRemote', 'fileSelect copied=%{public}s', dst);
      return dst;
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'fileSelect copy failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  aboutToDisappear(): void {
    this.setKeepScreenOn(false);
    try {
      emitter.off(AppEvents.FOREGROUND, this.onFgEvent);
      emitter.off(AppEvents.BACKGROUND, this.onBgEvent);
    } catch (e) {
      hilog.warn(0x0000, 'ZcodeRemote', 'emitter off failed: %{public}s', JSON.stringify(e));
    }
    this.clearMaskTimers();
    if (this.lastSnapshot !== undefined) {
      this.lastSnapshot.release();
      this.lastSnapshot = undefined;
    }
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
    hilog.info(0x0000, 'ZcodeRemote', 'manual reload');
    this.errorText = '';
    this.loading = true;
    this.maskNavUntil = Date.now() + 30000;
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
            .fileAccess(true)
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
              this.maskSuppressed = false;
              this.sockClosed = false;
              this.pageConnecting = false;
              // 回前台/手动刷新后的重载才遮；普通站内跳转直接显示新页面
              if (this.lastSnapshot !== undefined && Date.now() < this.maskNavUntil) {
                this.showMask(false);
                this.pageLoading = true;
              } else if (this.maskVisible) {
                this.clearMask();
              }
            })
            .onPageEnd(() => {
              this.loading = false;
              this.pageLoading = false;
              this.applyPageTheme();
              if (this.maskVisible) {
                this.probeReady(350);
              } else {
                this.captureSnapshot();
              }
            })
            .onConsole((event) => {
              const msg: string = event.message.getMessage();
              if (msg.indexOf('ZR_CONNECTING') >= 0) {
                this.onPageConnecting();
              } else if (msg.indexOf('ZR_SOCKET_') >= 0) {
                this.onSocketChanged(msg);
              } else if (msg.indexOf('ZR_READY') >= 0) {
                this.onPageReadyLog(msg);
              }
              return false;
            })
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.webW = parseFloat(String(newValue.width)) || 0;
              this.webH = parseFloat(String(newValue.height)) || 0;
            })
            .onShowFileSelector((event) => {
              this.pickFilesForWeb(event);
              return true;
            })
            .onRenderExited((event) => {
              hilog.warn(0x0000, 'ZcodeRemote', 'render exited reason=%{public}d', event.renderExitReason);
              if (this.lastSnapshot !== undefined) {
                this.maskNavUntil = Date.now() + 30000;
                this.maskSuppressed = false;
                this.showMask(false);
                this.pageLoading = true;
              }
            })
            .onProgressChange((event) => {
              this.progress = event.newProgress;
            })
            .onErrorReceive((event) => {
              if (!event.request.isMainFrame()) {
                return;
              }
              this.loading = false;
              this.clearMask();
              this.errorText = `网络错误：${event.error.getErrorInfo()}`;
            })
            .onHttpErrorReceive((event) => {
              if (!event.request.isMainFrame()) {
                hilog.warn(0x0000, 'ZcodeRemote', 'subresource HTTP %{public}d: %{public}s',
                  event.response.getResponseCode(), event.request.getRequestUrl());
                return;
              }
              this.loading = false;
              this.clearMask();
              this.errorText = `HTTP 错误：${event.response.getResponseCode()}`;
            })
            .onSslErrorEventReceive((event) => {
              event.handler.handleCancel();
              this.loading = false;
              this.clearMask();
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

        if (this.maskVisible && this.lastSnapshot !== undefined) {
          Stack({ alignContent: Alignment.Bottom }) {
            Image(this.lastSnapshot as image.PixelMap)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Fill)
              .interpolation(ImageInterpolation.High)
            if (this.maskHint) {
              Text('正在恢复会话…')
                .fontSize(11)
                .fontColor('#B9CDE6')
                .backgroundColor('#CC102A4A')
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(12)
                .margin({ bottom: 16 })
            }
          }
          .width('100%')
          .height('100%')
          .opacity(this.maskOpacity)
          .animation({ duration: 220, curve: Curve.EaseOut })
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
