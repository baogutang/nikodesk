/* Design review only. Readiness is simulated; no native initialization or networking. */
(() => {
  'use strict';
  const q = s => document.querySelector(s);
  const descriptions = {
    a: ['DIRECTION 01', '干净的弹性，恰到好处的光。', '两条细光轨围绕标识归位，蓝色图标轻盈落定，然后让位给工作界面。借鉴 ZCode 的短促节奏，保留 NikoDesk 自己的识别。'],
    b: ['DIRECTION 02', '两扇窗口，一处工作空间。', '两扇轻薄的窗口从两侧靠近，在相遇时收束成 NikoDesk 标识，再展开为工作界面。更有叙事感，强调连接两端的关系。'],
    c: ['DIRECTION 03', '在暖纸上，轻轻出现。', '纸色背景上，柔和轮廓呼吸一次，标识与文字自然浮现。更克制，适合每天多次打开，也与客户端的暖纸界面保持连续。']
  };
  let mode = 'a', timeline;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  q('#reduce').checked = reduced.matches;
  function play() {
    timeline?.kill();
    const minimal = q('#reduce').checked;
    const scenario = q('#scenario').value;
    const readyAt = {normal:1.45,fast:.32,slow:4.8,failure:2.5}[scenario];
    q('.preview').dataset.mode = mode;
    q('#pause').textContent = '暂停';
    q('#pause').setAttribute('aria-pressed','false');
    q('#status').textContent = '模拟启动中';
    q('.slow-note').textContent = '';
    const [num,title,copy] = descriptions[mode];
    q('#direction-number').textContent = num;
    q('#direction-title').textContent = title;
    q('#direction-copy').textContent = copy;
    gsap.set('.splash',{autoAlpha:1});
    gsap.set('.workspace',{autoAlpha:0,y:0,scale:1});
    gsap.set('.logo,.wordmark,.tagline,.orbit,.sheet,.paper,.halo,.loading-line',{clearProps:'all'});
    gsap.set('.logo',{opacity:0,scale:.75});
    gsap.set('.wordmark,.tagline',{opacity:0,y:8});
    gsap.set('.loading-line i',{x:-25});
    timeline = gsap.timeline();
    if (minimal) {
      timeline.set('.logo,.wordmark,.tagline',{opacity:1,scale:1,y:0});
      timeline.set('.loading-line',{opacity:0});
    } else if (mode === 'a') {
      timeline.fromTo('.o1',{opacity:0,scale:1.3,rotation:-140},{opacity:.85,scale:1,rotation:30,duration:.7,ease:'power2.out'},0)
        .fromTo('.o2',{opacity:0,scale:1.15,rotation:50},{opacity:.6,scale:1,rotation:205,duration:1,ease:'power2.out'},.08)
        .to('.halo',{opacity:1,duration:.6},0)
        .to('.logo',{opacity:1,scale:1,duration:.75,ease:'back.out(1.7)'},.08)
        .to('.wordmark,.tagline',{opacity:1,y:0,duration:.45,stagger:.1,ease:'power2.out'},.4)
        .to('.orbit',{opacity:0,scale:.65,duration:.5,ease:'power2.inOut'},.72);
    } else if (mode === 'b') {
      timeline.fromTo('.s1',{x:-170,y:18,rotation:-10,opacity:0},{x:-50,y:-8,rotation:-5,opacity:1,duration:.65,ease:'power3.out'},0)
        .fromTo('.s2',{x:170,y:-12,rotation:10,opacity:0},{x:50,y:8,rotation:5,opacity:1,duration:.65,ease:'power3.out'},.08)
        .to('.sheet',{x:0,y:0,rotation:0,scale:.5,opacity:0,duration:.45,ease:'power3.inOut'},.55)
        .to('.logo',{scale:1,opacity:1,duration:.55,ease:'back.out(1.3)'},.72)
        .to('.wordmark,.tagline',{opacity:1,y:0,stagger:.08,duration:.4},.87);
    } else {
      timeline.fromTo('.paper',{opacity:0,scale:.75,rotation:38},{opacity:1,scale:1,rotation:45,stagger:.12,duration:1.1,ease:'sine.out'},0)
        .to('.logo',{opacity:1,scale:1,duration:.85,ease:'sine.out'},.12)
        .to('.wordmark,.tagline',{opacity:1,y:0,duration:.7,stagger:.12},.32)
        .to('.paper',{opacity:.28,scale:1.04,duration:.8},1.1);
    }
    if (!minimal) timeline.to('.loading-line i',{x:65,duration:1,ease:'sine.inOut',repeat:5},0);
    // Slow work is explained; never manufacture a successful UI after a timeout.
    if (readyAt > 2) timeline.call(() => {q('.slow-note').textContent='正在准备工作空间…';},[],2);
    timeline.call(() => {
      if (scenario === 'failure') {
        timeline.pause();
        q('.slow-note').textContent='暂时无法完成初始化，请重新启动后再试。';
        q('#status').textContent='模拟初始化失败 · 保留明确说明';
        q('#pause').textContent='继续';
        q('#pause').disabled=true;
        return;
      }
      q('#status').textContent='模拟已就绪 · 正在进入';
      // Exit starts at readiness, even when it interrupts the opening motif.
      timeline.pause();
      const exit=gsap.timeline({onComplete:()=>{q('#status').textContent='播放完成 · 界面示意';q('#pause').disabled=true;}});
      exit.to('.splash',{autoAlpha:0,duration:minimal?.1:.24})
          .fromTo('.workspace',{autoAlpha:0,y:minimal?0:9},{autoAlpha:1,y:0,duration:minimal?.1:.32},0);
      timeline=exit;
    },[],readyAt);
    q('#pause').disabled=false;
  }
  document.querySelectorAll('.choice').forEach(button=>button.addEventListener('click',()=>{
    mode=button.dataset.mode;
    document.querySelectorAll('.choice').forEach(b=>{const active=b===button;b.classList.toggle('active',active);b.setAttribute('aria-pressed',String(active));});
    play();
  }));
  q('#replay').addEventListener('click',play);
  q('#still').addEventListener('click',()=>{q('#scenario').value='slow';play();timeline.pause(mode==='b'?.45:.82);q('#pause').textContent='继续';q('#pause').setAttribute('aria-pressed','true');q('#status').textContent='定格预览 · 可继续播放';});
  q('#scenario').addEventListener('change',play);
  q('#reduce').addEventListener('change',play);
  q('#pause').addEventListener('click',()=>{if(!timeline)return;const paused=!timeline.paused();timeline.paused(paused);q('#pause').textContent=paused?'继续':'暂停';q('#pause').setAttribute('aria-pressed',String(paused));});
  play();
})();
