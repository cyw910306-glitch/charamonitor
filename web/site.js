/* 캐릭모니터 site: menu bar header, language, copy, install tabs, desktop icons and the feature demos.
   Plain JS, no build. Every demo starts the first time its card comes within 200px of the screen. */
(function(){
'use strict';
var D = document, H = D.documentElement;
var still = matchMedia('(prefers-reduced-motion: reduce)');
var lang = H.classList.contains('en') ? 'en' : 'ko';
function L(ko, en){ return lang === 'en' ? en : ko; }
function P(pair){ return pair[lang === 'en' ? 1 : 0]; }
function $(s, r){ return (r || D).querySelector(s); }
function $$(s, r){ return Array.prototype.slice.call((r || D).querySelectorAll(s)); }
function store(k, v){ try{ if(v === undefined) return localStorage.getItem(k); if(v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); }catch(e){} return null; }
function pick(a){ return a[Math.floor(Math.random() * a.length)]; }
function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
function pad2(n){ return (n < 10 ? '0' : '') + n; }

/* ---------- language ---------- */
var langCbs = [];
function onLang(f){ langCbs.push(f); f(); }
var ATTRS = [['label','aria-label'], ['title','title'], ['alt','alt'], ['ph','placeholder']];
function applyAttrs(){
  ATTRS.forEach(function(a){
    $$('[data-' + a[0] + '-en]').forEach(function(el){
      if(el.dataset[a[0] + 'Ko'] === undefined) el.dataset[a[0] + 'Ko'] = el.getAttribute(a[1]) || '';
      el.setAttribute(a[1], lang === 'en' ? el.dataset[a[0] + 'En'] : el.dataset[a[0] + 'Ko']);
    });
  });
  var b = D.body;
  if(b.dataset.titleEn){ if(!b.dataset.titleKo) b.dataset.titleKo = D.title; D.title = lang === 'en' ? b.dataset.titleEn : b.dataset.titleKo; }
  $$('[data-lang]').forEach(function(x){ x.setAttribute('aria-pressed', String(x.dataset.lang === lang)); });
}
function setLang(l){
  lang = l; H.classList.toggle('en', l === 'en'); H.lang = l; store('cm.lang', l);
  applyAttrs(); langCbs.forEach(function(f){ f(); });
}
D.addEventListener('click', function(e){
  var b = e.target.closest && e.target.closest('button[data-lang]');
  if(b){ setLang(b.dataset.lang); var m = b.closest('details'); if(m) m.open = false; }
});
applyAttrs();
// support, privacy, sponsor: their own #ko / #en sections also switch the header and footer
if(D.body.dataset.hashlang){ var hashLang = function(){ if(location.hash === '#en') setLang('en'); else if(location.hash === '#ko') setLang('ko'); else if(!location.hash && store('cm.lang') === 'en') setLang('en'); }; addEventListener('hashchange', hashLang); hashLang(); }

/* a polite live region for "복사됨" and demo results */
var live = D.createElement('p'); live.className = 'vh'; live.setAttribute('aria-live', 'polite'); D.body.appendChild(live);
function say(t){ live.textContent = ''; setTimeout(function(){ live.textContent = t; }, 30); }

/* ---------- sprites ---------- */
// index.json: characters[].rows[]{key,n,s}; a row's place is its y, frame width = sheet width / the sheet's largest n.
var IDX = null, IMGS = {};
function index(){
  return IDX || (IDX = fetch('app/sprites/index.json').then(function(r){ return r.json(); }).then(function(d){
    var m = {}, order = [];
    d.characters.forEach(function(c){
      var rows = {}, max = 1;
      c.rows.forEach(function(r, i){ rows[r.key] = { y: i, n: r.n, s: r.s }; max = Math.max(max, r.n); });
      m[c.id] = { id: c.id, name: c.name, file: 'app/sprites/' + c.sheet, rows: rows, max: max, nrows: c.rows.length };
      order.push(c.id);
    });
    m._order = order; return m;
  }));
}
function img(src){
  return IMGS[src] || (IMGS[src] = new Promise(function(ok, no){ var i = new Image(); i.onload = function(){ ok(i); }; i.onerror = no; i.src = src; }));
}
var SHEETS = {};
function sheet(id){
  return SHEETS[id] || (SHEETS[id] = index().then(function(m){
    var c = m[id];
    return img(c.file).then(function(i){ c.img = i; c.fw = i.naturalWidth / c.max; c.fh = i.naturalHeight / c.nrows; return c; });
  }));
}
// ChatGPT (Codex) pet sheets: 8 columns of 192x208, the second row runs right.
function gptSheet(id){
  return img('gpt-pets/' + id + '/spritesheet.png').then(function(i){ return { img: i, fw: 192, fh: 208, rows: { run: { y: 1, n: 8, s: 0.1 }, idle: { y: 0, n: 6, s: 0.2 } } }; });
}
function row(c, key){ return c.rows[key] || c.rows[key === 'special' ? 'sprint' : 'walk'] || c.rows.run; }
// Draws one frame bottom-centred in (or at x,y of) the canvas.
function drawSprite(ctx, c, key, frame, scale, x, y, flip){
  var r = row(c, key), w = c.fw * scale, h = c.fh * scale;
  if(x == null){ x = (ctx.canvas.width - w) / 2; y = ctx.canvas.height - h; }
  ctx.save(); ctx.imageSmoothingEnabled = false;
  if(flip){ ctx.translate(x + w, y); ctx.scale(-1, 1); x = 0; y = 0; }
  ctx.drawImage(c.img, (frame % r.n) * c.fw, r.y * c.fh, c.fw, c.fh, x, y, w, h);
  ctx.restore();
}
function drawStill(cv, id, key, frame){
  return sheet(id).then(function(c){ var g = cv.getContext('2d'); g.clearRect(0, 0, cv.width, cv.height); drawSprite(g, c, key, frame || 0, Math.max(1, Math.floor(Math.min(cv.width / c.fw, cv.height / c.fh)))); });
}

/* ---------- one loop for every moving sprite: only on screen, only while the tab is visible ---------- */
var pets = [], raf = 0, timer = 0;
var visIO = window.IntersectionObserver ? new IntersectionObserver(function(es){
  es.forEach(function(e){ var p = e.target._pet; if(p){ p.vis = e.isIntersecting; } });
  wake();
}) : null;
function Pet(cv, src, pose, opt){
  opt = opt || {};
  this.cv = cv; this.g = cv.getContext('2d'); this.pose = pose; this.t0 = performance.now(); this.last = -1;
  this.scale = opt.scale; this.group = opt.group || null; this.flip = false; this.step = opt.step || null; this.vis = !visIO;
  cv._pet = this; pets.push(this); if(visIO) visIO.observe(cv);
  this.setChar(src);
}
Pet.prototype.setChar = function(src){
  var p = this, pr = typeof src === 'string' ? sheet(src) : src;
  p.want = pr;
  pr.then(function(c){ if(p.want !== pr) return; p.c = c; if(!p.scale) p.scale = Math.max(0.25, Math.floor(p.cv.width / c.fw) || p.cv.width / c.fw); p.last = -1; p.draw(performance.now(), true); wake(); });
};
Pet.prototype.setPose = function(k){
  if(k === this.pose) return;
  this.pose = k; this.t0 = performance.now(); this.last = -1; this.draw(this.t0, true); wake();
};
Pet.prototype.frame = function(now){
  if(!this.c || still.matches || this.rest) return 0;
  var r = row(this.c, this.pose); return Math.floor(Math.max(0, now - this.t0) / 1000 / r.s) % r.n;
};
Pet.prototype.draw = function(now, force){
  if(!this.c) return;
  var f = this.frame(now);
  if(!force && f === this.last) return;
  this.last = f; this.g.clearRect(0, 0, this.cv.width, this.cv.height);
  drawSprite(this.g, this.c, this.pose, f, this.scale, null, null, this.flip);
};
function active(){
  if(D.hidden) return [];
  var vis = pets.filter(function(p){ return p.vis && p.c; });
  // a page keeps one demo moving at a time (the one nearest the middle), plus the menu bar
  var groups = vis.filter(function(p){ return p.group; }), best = null, bd = 1e9, mid = innerHeight / 2;
  groups.forEach(function(p){ var b = p.group.getBoundingClientRect(), d = Math.abs(b.top + b.height / 2 - mid); if(d < bd){ bd = d; best = p.group; } });
  vis.forEach(function(p){
    var r = !!(p.group && p.group !== best);
    if(r !== !!p.rest){ p.rest = r; p.last = -1; p.draw(performance.now(), true); }
  });
  return vis.filter(function(p){ return !p.rest; });
}
function wake(){ if(!raf && !timer) schedule(); }
function schedule(){
  var act = active();
  if(!act.length || still.matches) return;
  var slow = act.every(function(p){ return !p.step && row(p.c, p.pose).s >= 0.3; });   // a nap ticks on a timer, not every frame
  if(slow) timer = setTimeout(function(){ timer = 0; tick(performance.now()); }, 200);
  else raf = requestAnimationFrame(function(t){ raf = 0; tick(t); });
}
function tick(now){
  active().forEach(function(p){ if(p.step) p.step(now); p.draw(now); });
  schedule();
}
D.addEventListener('visibilitychange', wake);
addEventListener('scroll', function(){ if(groupsExist()) wake(); }, { passive: true });
function groupsExist(){ return pets.some(function(p){ return p.group; }); }
still.addEventListener('change', function(){ pets.forEach(function(p){ p.last = -1; p.draw(performance.now(), true); }); wake(); });

/* ---------- CPU → pose ---------- */
var POSES = [[10,'lying'],[25,'slowWalk'],[45,'walk'],[65,'fastWalk'],[80,'run'],[95,'sprint'],[101,'exhausted']];
var POSE_NAME = { lying: ['누워서 쉬어요','Resting'], slowWalk: ['느릿느릿 걸어요','Strolling'], walk: ['걸어요','Walking'], fastWalk: ['빨리 걸어요','Brisk walk'],
  run: ['달려요','Running'], sprint: ['전력 질주','Sprinting'], exhausted: ['지쳤어요','Worn out'] };
function poseFor(v){ for(var i = 0; i < POSES.length; i++) if(v < POSES[i][0]) return POSES[i][1]; return 'exhausted'; }

/* ---------- header: running Jelly, example CPU, clock, dashboard preview ---------- */
var mbPet = null, cpu = 12, held = 0;
var mbCv = $('.mb .pet canvas');
if(mbCv){ mbPet = new Pet(mbCv, 'dog-jelly', poseFor(cpu), { scale: 1 }); }
function showCpu(v, manual){
  cpu = Math.round(v); if(manual) held = Date.now();
  $$('.mb .cpu').forEach(function(e){ e.textContent = 'CPU ' + cpu + '%'; e.setAttribute('aria-label', 'CPU ' + cpu + '% ' + L('(예시)', '(example)')); });
  if(mbPet) mbPet.setPose(poseFor(cpu));
  var pop = $('#cm-pop'); if(pop && !pop.hidden) $('.bars', pop).innerHTML = barsHTML();
}
setInterval(function(){
  if(Date.now() - held < 8000 || D.hidden) return;
  showCpu(Math.max(3, Math.min(40, cpu + (Math.random() * 8 - 4))));
}, 2500);
function clock(){
  var d = new Date(), t = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  $$('.mb .clock, [data-clock]').forEach(function(e){ e.textContent = t; });
  setTimeout(clock, (60 - d.getSeconds()) * 1000 + 50);
}
clock();
function barsHTML(){
  var B = [[L('CPU','CPU'), cpu, cpu + '%'], [L('메모리','Memory'), 51, '8.1/16 GB'], [L('저장 용량','Storage'), 43, '212/494 GB'],
           [L('배터리','Battery'), 86, '86%'], [L('네트워크','Network'), 18, '↓1.2 MB/s']];
  return B.map(function(b){ return '<li><span>' + b[0] + '</span><span class="tr"><i style="width:' + b[1] + '%"></i></span><b>' + b[2] + '</b></li>'; }).join('');
}
var petBtn = $('.mb .pet'), scrim = null, pop = null;
function openPop(){
  if(!pop){
    scrim = D.createElement('div'); scrim.className = 'scrim'; scrim.hidden = true;
    scrim.addEventListener('click', closePop);   // a real element with its own click (iOS ignores taps on bare backgrounds)
    pop = D.createElement('div'); pop.className = 'pop'; pop.id = 'cm-pop'; pop.hidden = true; pop.tabIndex = -1;
    pop.setAttribute('role', 'dialog');
    D.body.appendChild(scrim); D.body.appendChild(pop);
    pop.addEventListener('keydown', function(e){ if(e.key === 'Escape') closePop(); });
  }
  pop.setAttribute('aria-label', L('대시보드 미리보기', 'Dashboard preview'));
  pop.innerHTML = '<h2>' + L('캐릭모니터 대시보드', 'CharaMonitor dashboard') + '</h2><ul class="bars">' + barsHTML() + '</ul>' +
    '<p class="cap">' + L('예시 화면', 'Example screen') + '</p><a href="features.html#menubar">' + L('기능 더 보기', 'More features') + '</a>';
  scrim.hidden = false; pop.hidden = false; pop.classList.add('enter');
  requestAnimationFrame(function(){ pop.classList.remove('enter'); });
  petBtn.setAttribute('aria-expanded', 'true'); pop.focus();
}
function closePop(){
  if(!pop || pop.hidden) return;
  pop.hidden = true; scrim.hidden = true; petBtn.setAttribute('aria-expanded', 'false'); petBtn.focus();
}
if(petBtn){
  petBtn.addEventListener('click', function(){ pop && !pop.hidden ? closePop() : openPop(); });
  D.addEventListener('keydown', function(e){ if(e.key === 'Escape') closePop(); });
}
// the mobile menu sheet closes on Esc and when a link inside is used
$$('.mb details.menu').forEach(function(m){
  m.addEventListener('keydown', function(e){ if(e.key === 'Escape'){ m.open = false; $('summary', m).focus(); } });
  m.addEventListener('click', function(e){ if(e.target.closest('a')) m.open = false; });
});

/* ---------- copy ---------- */
function copyText(text){
  if(navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
  return new Promise(function(ok, fail){
    var ta = D.createElement('textarea'); ta.value = text; ta.setAttribute('readonly', '');
    ta.style.position = 'fixed'; ta.style.opacity = '0'; D.body.appendChild(ta); ta.select();
    try{ D.execCommand('copy') ? ok() : fail(); }catch(e){ fail(e); }
    D.body.removeChild(ta);
  });
}
$$('.copy[data-copy]').forEach(function(b){
  var orig = b.innerHTML;
  b.addEventListener('click', function(){
    var el = D.getElementById(b.dataset.copy);
    copyText(el.textContent).then(function(){
      b.textContent = L('복사됨', 'Copied'); b.classList.add('done'); say(L('복사됨', 'Copied'));
      setTimeout(function(){ b.innerHTML = orig; b.classList.remove('done'); }, 1600);
    }, function(){
      var sel = getSelection(), r = D.createRange(); r.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(r);
      b.textContent = L('직접 복사해 주세요', 'Copy it manually');
      setTimeout(function(){ b.innerHTML = orig; }, 2400);
    });
  });
});

/* ---------- version ---------- */
var ver = D.getElementById('ver');
if(ver) fetch('version.txt', { cache: 'no-store' }).then(function(r){ return r.ok ? r.text() : ''; }).then(function(t){
  t = (t || '').trim().split(/\s+/)[0]; if(t && t.length < 24) ver.textContent = t.replace(/^v/i, '');
}).catch(function(){});

/* ---------- reveal: opacity/transform only, with a sweep for jumps the observer misses ---------- */
var reveals = $$('.reveal');
function sweep(){ requestAnimationFrame(function(){ reveals.forEach(function(e){ if(!e.classList.contains('in') && e.getBoundingClientRect().top < innerHeight) e.classList.add('in'); }); }); }
if(reveals.length){
  if(window.IntersectionObserver){
    var rio = new IntersectionObserver(function(es){ es.forEach(function(e){ if(e.isIntersecting){ e.target.classList.add('in'); rio.unobserve(e.target); } }); },
      { threshold: 0.15, rootMargin: '0px 0px -10% 0px' });
    reveals.forEach(function(e){ rio.observe(e); });
  } else reveals.forEach(function(e){ e.classList.add('in'); });
  addEventListener('scroll', sweep, { passive: true });
  addEventListener('hashchange', sweep);
  addEventListener('load', function(){ sweep(); setTimeout(function(){ reveals.forEach(function(e){ e.classList.add('in'); }); }, 600); });
  sweep();
}

/* ---------- fortune lines (Fortune.swift, with the app's English) ---------- */
var F = {
  head: [['오늘은 메일 답장이 술술 써지는 날이에요.','Emails will practically write themselves today.'],['회의가 예정보다 5분 일찍 끝날 기운이 보여요.','Your meeting looks set to end five minutes early.'],
    ['커피가 유난히 맛있게 내려지는 하루예요.','Your coffee will taste unusually good today.'],['오늘 한 일은 내일의 내가 고마워할 거예요.',"Tomorrow's you will thank you for today's work."],
    ['퇴근 시간이 평소보다 가깝게 느껴지는 날이에요.','Clocking-out time feels closer than usual today.'],['미뤄 둔 일 하나가 생각보다 금방 끝나요.','That task you put off will be done sooner than you think.'],
    ['엘리베이터 운이 좋아요. 기다리면 바로 와요.','Elevator luck is on your side. It comes right away.'],['작은 칭찬 하나가 하루를 데워 줄 거예요.','One small compliment will warm up your day.'],
    ['키보드가 손에 착 붙는 날이에요. 오타도 적어요.','The keyboard feels just right today. Fewer typos, too.'],['점심 메뉴 고민이 3초 만에 끝나는 날이에요.','Lunch will be decided in three seconds today.'],
    ['오늘의 나는 생각보다 일을 잘해요.',"You're better at your job today than you think."],['할 일 목록에 체크 표시가 늘어나는 기운이 있어요.','Your to-do list is about to fill up with check marks.'],
    ['와이파이도 나도 오늘은 신호가 좋아요.','The Wi-Fi and you both have a strong signal today.'],['느긋하게 시작해도 결국 다 해내는 날이에요.','Start slow, still finish everything today.'],
    ['누군가 내 자리에 간식을 두고 갈지도 몰라요.','Someone might leave a snack on your desk.']],
  work: [['첫 메일 하나만 보내면 나머지는 따라와요.','Send the first email and the rest will follow.'],['회의록은 내가 쓰면 칭찬받아요.',"Write the meeting notes and you'll get the credit."],
    ['파일 이름을 잘 지어 두면 오후가 편해요.','Name your files well and the afternoon goes easy.'],['어려운 일은 오전에, 쉬운 일은 오후에.','Hard work in the morning, easy work in the afternoon.'],
    ['저장 버튼을 자주 누르면 행운이 따라요.','Hit save often and luck follows.'],['오늘 고친 문제는 다시 안 나와요.',"The bug you fix today won't come back."],
    ['질문 하나가 한 시간을 아껴 줘요.','One question saves an hour.'],['슬라이드 한 장을 덜면 발표가 가벼워져요.','Drop one slide and the talk gets lighter.'],
    ['답장은 짧게, 인사는 다정하게.','Keep replies short and greetings warm.'],['탭을 몇 개 닫으면 머리도 맑아져요.','Close a few tabs and your head clears too.'],
    ['오늘 정한 마감은 여유 있게 지켜져요.',"Today's deadline will be met with room to spare."],['미뤄 둔 그 일, 10분만 해 보면 반은 끝나요.',"That task you put off: ten minutes and it's half done."]],
  money: [['커피 쿠폰 도장이 하나 더 찍히는 날이에요.','One more stamp on your coffee card today.'],['장바구니는 하루 묵히면 더 현명해져요.',"Let the shopping cart sit a day and you'll shop smarter."],
    ['잊고 있던 포인트를 발견할 수 있어요.','You may find points you forgot you had.'],['오늘의 지출은 나를 위한 작은 투자예요.',"Today's spending is a small investment in you."],
    ['무료 배송 기준을 딱 맞출 운이에요.',"You'll hit the free shipping minimum just right."],['주머니에서 반가운 동전이 나와요.','A welcome coin turns up in your pocket.'],
    ['구독 하나를 점검하면 지갑이 웃어요.','Check one subscription and your wallet smiles.'],['할인 알림이 반가운 소식을 가져와요.','A sale alert brings good news.'],
    ['오늘은 사는 것보다 아끼는 게 더 신나요.','Saving is more fun than buying today.'],['영수증을 챙기면 나중에 도움이 돼요.',"Keep your receipts. They'll help later."]],
  people: [['먼저 건넨 인사가 좋은 대화로 이어져요.','A hello you start turns into a good chat.'],['옆자리 동료와 웃을 일이 생겨요.',"You'll share a laugh with the person next to you."],
    ['오랜만에 연락 온 사람이 반가운 소식을 줘요.',"Someone you haven't heard from in a while brings good news."],['고맙다는 말 한마디가 두 배로 돌아와요.','A thank-you comes back twice as big.'],
    ['오늘은 들어 주는 쪽이 이기는 날이에요.','Today the listener wins.'],['이모티콘 하나로 분위기가 풀려요.','One emoji lightens the mood.'],
    ['점심을 같이 먹는 사람과 더 친해져요.',"You'll get closer to whoever you have lunch with."],['부탁할 일이 있다면 오늘이 좋아요.','If you need a favor, today is a good day to ask.'],
    ['칭찬은 구체적으로 하면 효과가 커요.','Specific praise works best.'],['단톡방에서 내 농담이 통해요.','Your joke lands in the group chat.']],
  snack: [['오후 3시의 초콜릿 한 조각이 기운을 줘요.','A square of chocolate at 3 p.m. gives you a boost.'],['따뜻한 차 한 잔이 머리를 맑게 해요.','A cup of warm tea clears your head.'],
    ['바삭한 과자가 회의 뒤 피로를 씻어 줘요.','A crunchy snack washes away post-meeting fatigue.'],['오늘은 과일 간식이 행운을 불러요.','Fruit snacks bring luck today.'],
    ['편의점 신상 간식이 성공할 확률이 높아요.','The new convenience store snack is likely a hit.'],['물을 한 잔 더 마시면 컨디션이 올라가요.','One more glass of water lifts your mood.'],
    ['달콤한 빵은 반만 먹고 반은 나눠 주세요.','Eat half the sweet bread and share the other half.'],['아이스보다 따뜻한 음료가 잘 맞아요.','A warm drink suits you better than an iced one.'],
    ['견과류 한 줌이 오후를 버티게 해 줘요.','A handful of nuts gets you through the afternoon.'],['간식 서랍을 정리하면 숨은 보물이 나와요.','Tidy the snack drawer and find hidden treasure.']],
  item: [['노란 포스트잇','Yellow sticky note'],['파란 볼펜','Blue ballpoint pen'],['머그컵','Mug'],['무선 이어폰','Wireless earbuds'],['핸드크림','Hand cream'],['형광펜','Highlighter'],
    ['텀블러','Tumbler'],['사원증 줄','Lanyard'],['스테이플러','Stapler'],['작은 화분','Small plant'],['귤','Tangerine'],['보조 배터리','Power bank']],
  color: [['하늘색','Sky blue'],['민트','Mint'],['귤색','Tangerine'],['연두','Lime green'],['라벤더','Lavender'],['크림색','Cream'],['남색','Navy'],['살구색','Apricot'],['버건디','Burgundy'],['레몬색','Lemon']]
};
var AREAS = [['work', ['업무','Work']], ['money', ['돈','Money']], ['people', ['사람','People']], ['snack', ['간식','Snacks']]];
function today(){ var d = new Date(); return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()); }
function hash(s){ var h = 2166136261; for(var i = 0; i < s.length; i++){ h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
// like Fortune.reading: each field steps by a nonzero amount per draw, so 다시 뽑기 changes every line
function reading(draw){
  var day = today();
  function at(pool, slot){ var n = pool.length, base = hash(day + ':' + slot) % n, step = 1 + hash(day + '/' + slot) % (n - 1); return pool[(base + draw * step) % n]; }
  return { day: day, head: at(F.head, 0), areas: AREAS.map(function(a, i){ return [a[1], at(F[a[0]], i + 1)]; }), item: at(F.item, 5), color: at(F.color, 6), stars: 3 + hash(day + '*' + draw) % 3 };
}
var fortuneDraw = 0;
// the app allows one redraw a day (Fortune.swift redrawsPerDay = 1); the demo keeps that rule
function redrawSpent(b){ if(fortuneDraw < 1) return; b.disabled = true; b.innerHTML = '<span lang="ko">다시 뽑기는 내일 또 돼요</span><span lang="en">You can draw again tomorrow</span>'; }

/* index: 오늘의 운세.txt opens a dialog */
var fdlg = D.getElementById('fortune-dlg');
if(fdlg){
  var fillF = function(){ var r = reading(fortuneDraw); $('#fortune-day').textContent = r.day + ' · ' + '★★★★★'.slice(0, r.stars) + '☆☆'.slice(0, 5 - r.stars); $('#fortune-line').textContent = P(r.head); };
  $('#ic-fortune').addEventListener('click', function(e){ if(this._moved) return; fillF(); if(fdlg.showModal) fdlg.showModal(); else fdlg.setAttribute('open', ''); });
  $('#fortune-again').addEventListener('click', function(){ if(fortuneDraw >= 1) return; fortuneDraw++; fillF(); redrawSpent(this); });
  $('#fortune-close').addEventListener('click', function(){ fdlg.close ? fdlg.close() : fdlg.removeAttribute('open'); });
  fdlg.addEventListener('click', function(e){ if(e.target === fdlg) fdlg.close(); });
  onLang(function(){ if(fdlg.open) fillF(); });
}

/* ---------- home: CPU slider, stickers, tabs, icons, grass ---------- */
var cpuTry = D.getElementById('cpu-try');
if(cpuTry){
  var cpuPose = D.getElementById('cpu-pose'), cpuOut = D.getElementById('cpu-out');
  var upd = function(manual){ var v = +cpuTry.value; cpuOut.textContent = v; cpuPose.textContent = P(POSE_NAME[poseFor(v)]); if(manual) showCpu(v, true); };
  cpuTry.addEventListener('input', function(){ upd(true); });
  onLang(function(){ upd(false); });
}
function stickers(){
  $$('canvas[data-stk]').forEach(function(cv){ var a = cv.dataset.stk.split(':'); drawStill(cv, a[0], a[1], 0); });
  var g = $('.ic .gst'); if(g) g.style.backgroundImage = 'url(gpt-pets/dog-jelly/spritesheet.png)';
}
if($('canvas[data-stk]')){ if(D.readyState === 'complete') stickers(); else addEventListener('load', stickers); }
// cards on the home page draw their still sprite when they come near
var lazyIO = window.IntersectionObserver ? new IntersectionObserver(function(es){
  es.forEach(function(e){ if(!e.isIntersecting) return; lazyIO.unobserve(e.target); var a = e.target.dataset.lazy.split(':'); drawStill(e.target, a[0], a[1], +a[2] || 0); });
}, { rootMargin: '200px' }) : null;
$$('canvas[data-lazy]').forEach(function(cv){ if(lazyIO) lazyIO.observe(cv); else { var a = cv.dataset.lazy.split(':'); drawStill(cv, a[0], a[1], +a[2] || 0); } });

/* install tabs: #install, #download, #iphone open their tab; no JS shows all three */
var tabs = $$('.tabs [role=tab]');
function selTab(id, focus){
  tabs.forEach(function(t){
    var on = t.getAttribute('aria-controls') === id;
    t.setAttribute('aria-selected', String(on)); t.tabIndex = on ? 0 : -1;
    D.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    if(on && focus) t.focus();
  });
}
function tabFromHash(scroll){
  var h = location.hash.slice(1);
  if(tabs.some(function(t){ return t.getAttribute('aria-controls') === h; })){
    selTab(h);
    if(scroll) requestAnimationFrame(function(){ D.getElementById('get').scrollIntoView({ behavior: still.matches ? 'auto' : 'smooth', block: 'start' }); sweep(); });
    return true;
  }
}
if(tabs.length){
  tabs.forEach(function(t, i){
    t.addEventListener('click', function(){ selTab(t.getAttribute('aria-controls')); });
    t.addEventListener('keydown', function(e){
      var j = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : null;
      if(j === null) return; e.preventDefault(); j = (j + tabs.length) % tabs.length; selTab(tabs[j].getAttribute('aria-controls'), true);
    });
  });
  if(!tabFromHash(true)) selTab('install');
  addEventListener('hashchange', function(){ tabFromHash(true); });
  // the same hash twice fires no hashchange: open the tab on the click too
  D.addEventListener('click', function(e){
    var a = e.target.closest && e.target.closest('a[href]'); if(!a || a._moved) return;
    var u = new URL(a.href, location.href);
    if(u.pathname === location.pathname && u.hash && u.hash === location.hash && tabs.some(function(t){ return '#' + t.getAttribute('aria-controls') === u.hash; })){ e.preventDefault(); tabFromHash(true); }
  });
}

/* desktop icons: a click opens; dragging (5px+) moves them and is saved here only */
var iconsBox = $('.icons');
if(iconsBox){
  var big = matchMedia('(min-width:1024px)'), saved = {};
  try{ saved = JSON.parse(store('cm.icons') || '{}') || {}; }catch(e){ saved = {}; }
  var place = function(ic, x, y){ ic.style.left = x + 'px'; ic.style.top = y + 'px'; ic.style.right = 'auto'; };
  $$('.ic', iconsBox).forEach(function(ic){
    ic.dataset.orig = ic.getAttribute('style') || '';
    if(saved[ic.id]) place(ic, saved[ic.id].x, saved[ic.id].y);
    ic.setAttribute('draggable', 'false');
    ic.addEventListener('dragstart', function(e){ e.preventDefault(); });
    var st = null, moving = false;
    ic.addEventListener('pointerdown', function(e){
      if(!big.matches || e.button !== 0) return;
      st = { x: e.clientX, y: e.clientY, ox: ic.offsetLeft, oy: ic.offsetTop, id: e.pointerId }; moving = false;
    });
    ic.addEventListener('pointermove', function(e){
      if(!st) return;
      var dx = e.clientX - st.x, dy = e.clientY - st.y;
      if(!moving && Math.abs(dx) + Math.abs(dy) > 5){ moving = true; ic.classList.add('drag'); try{ ic.setPointerCapture(st.id); }catch(err){} }
      if(moving){
        var maxX = iconsBox.clientWidth - ic.offsetWidth, maxY = iconsBox.clientHeight - ic.offsetHeight;
        place(ic, Math.max(0, Math.min(maxX, st.ox + dx)), Math.max(0, Math.min(maxY, st.oy + dy)));
      }
    });
    var end = function(){
      if(moving){
        ic.classList.remove('drag'); ic._moved = true; setTimeout(function(){ ic._moved = false; }, 350);
        saved[ic.id] = { x: ic.offsetLeft, y: ic.offsetTop }; store('cm.icons', JSON.stringify(saved));
      }
      st = null; moving = false;
    };
    ic.addEventListener('pointerup', end); ic.addEventListener('pointercancel', end);
    ic.addEventListener('click', function(e){ if(ic._moved){ e.preventDefault(); e.stopImmediatePropagation(); ic._moved = false; } }, true);
  });
  var resetBtn = D.getElementById('icons-reset');
  if(resetBtn) resetBtn.addEventListener('click', function(){
    saved = {}; store('cm.icons', null);
    $$('.ic', iconsBox).forEach(function(ic){ ic.setAttribute('style', ic.dataset.orig); });
  });
}

/* #play: drag and throw our own original 태닝 고양이 (web/demo-tancat.png from tools/originals-set2/web_demo.py).
   Faster means a faster pose, left alone it naps, a tap is a 킥플립. Reduced motion: no gravity, no frame changes.
   The loop sleeps when nothing moves: a nap ticks at its own 3 fps, off screen or reduced and still it stops. */
(function(){
  var cv = $('#play canvas'); if(!cv) return;
  var g = cv.getContext('2d'), sheetImg = new Image();
  var FW = 34, FH = 20, Z = 4, w = FW * Z, h = FH * Z, H2 = 120, W = 0;
  var ROW = { lying: [0, 4], walk: [1, 4], run: [2, 4], sprint: [3, 6], special: [4, 8] };   // web_demo.py ROWS
  var x = 40, y = H2 - h, vx = 0, vy = 0, face = 1, t = 0, idle = 0, wander = 0, trick = -1, hold = null, last = 0, running = false, nap = 0, seen = true;
  var clamp = function(v, lo, hi){ return Math.max(lo, Math.min(hi, v)); };
  function size(){ var r = devicePixelRatio || 1; W = cv.clientWidth; cv.width = W * r; cv.height = H2 * r; g.setTransform(r, 0, 0, r, 0, 0); g.imageSmoothingEnabled = false; x = clamp(x, 0, W - w); }
  function at(e){ var b = cv.getBoundingClientRect(); return { x: e.clientX - b.left, y: e.clientY - b.top, t: e.timeStamp }; }
  cv.addEventListener('pointerdown', function(e){
    var p = at(e); if(p.x < x || p.x > x + w || p.y < y || p.y > y + h) return;
    hold = { dx: p.x - x, dy: p.y - y, start: p, prev: p, moved: false }; idle = 0; wander = 0;
    cv.setPointerCapture(e.pointerId); cv.classList.add('held'); kick();
  });
  cv.addEventListener('pointermove', function(e){
    if(!hold) return; var p = at(e), dt = Math.max(1, p.t - hold.prev.t) / 1000;
    if(Math.abs(p.x - hold.start.x) + Math.abs(p.y - hold.start.y) > 5) hold.moved = true;
    vx = clamp(vx * .5 + (p.x - hold.prev.x) / dt * .5, -3000, 3000); vy = clamp(vy * .5 + (p.y - hold.prev.y) / dt * .5, -3000, 3000);
    hold.prev = p; x = clamp(p.x - hold.dx, 0, W - w); y = clamp(p.y - hold.dy, 0, H2 - h);
  });
  function drop(){
    if(!hold) return;
    if(!hold.moved){ trick = still.matches ? -1 : 0; vx = vy = 0; }
    if(still.matches){ vx = vy = 0; y = H2 - h; }
    hold = null; cv.classList.remove('held'); kick();
  }
  cv.addEventListener('pointerup', drop); cv.addEventListener('pointercancel', drop);
  // the button stand-in for a throw: a toss up and across, or with reduced motion a hop to a new spot
  var tb = D.getElementById('play-throw');
  if(tb) tb.addEventListener('click', function(){
    var dir = x + w / 2 < W / 2 ? 1 : -1; idle = 0; wander = 0;
    if(still.matches){ x = clamp(x + dir * W * 0.4, 0, W - w); face = dir; }
    else { vx = dir * (900 + Math.random() * 600); vy = -380 - Math.random() * 120; y = Math.min(y, H2 - h - 1); }
    kick();
  });
  function step(now){
    var real = (now - (last || now)) / 1000, dt = Math.min(.05, real), floor = H2 - h; last = now;
    if(hold){ vx *= Math.exp(-8 * dt); vy *= Math.exp(-8 * dt); }
    else if(!still.matches){
      vy += 2400 * dt; x += vx * dt; y += vy * dt;
      if(y >= floor){ y = floor; vy = Math.abs(vy) > 200 ? -vy * .35 : 0; vx *= Math.exp(-3 * dt); }
      if(x < 0 || x > W - w){ x = clamp(x, 0, W - w); vx = -vx * .5; }
      if(y === floor && Math.abs(vx) < 20 && trick < 0){
        vx = 0; idle += dt;
        if(idle > 2 && !wander && idle < 2.2) wander = (Math.random() < .5 ? -1 : 1) * 50;   // a short stroll, then a nap
        if(idle > 4) wander = 0;
        x = clamp(x + wander * dt, 0, W - w);
      } else idle = 0;
    }
    if(trick >= 0 && (trick += dt * 12) >= ROW.special[1]) trick = -1;   // before the pose, so the last frame is the rest pose
    var speed = Math.hypot(vx, vy), moving = Math.abs(vx) + Math.abs(wander);
    if(Math.abs(vx) > 5) face = vx > 0 ? 1 : -1; else if(wander) face = wander > 0 ? 1 : -1;
    var pose = trick >= 0 ? 'special' : hold ? (speed > 900 ? 'sprint' : 'run')
      : moving > 600 ? 'sprint' : moving > 200 ? 'run' : moving > 10 || idle < 2 ? 'walk' : 'lying';
    var fps = pose === 'special' ? 12 : pose === 'lying' ? 3 : Math.min(24, 6 + Math.max(speed, moving) / 60);
    var r = ROW[pose]; t += (pose === 'lying' ? Math.min(.5, real) : dt) * fps;
    var f = pose === 'special' ? Math.floor(trick)   // the flip runs from its first frame, not from the shared clock
      : still.matches || (pose === 'walk' && !hold && moving <= 10) ? 0 : Math.floor(t) % r[1];
    g.clearRect(0, 0, W, H2);
    g.save(); g.translate(face > 0 ? x : x + w, y); g.scale(face, 1); g.drawImage(sheetImg, f * FW, r[0] * FH, FW, FH, 0, 0, w, h); g.restore();
    if(!seen || D.hidden || (still.matches && !hold && trick < 0)){ running = false; return; }
    if(pose === 'lying'){ nap = setTimeout(function(){ nap = 0; requestAnimationFrame(step); }, 1000 / fps); return; }
    requestAnimationFrame(step);
  }
  function kick(){
    if(nap){ clearTimeout(nap); nap = 0; running = false; }   // a grab wakes the nap at once
    if(running || !sheetImg.naturalWidth) return; running = true;   // one frame even off screen, so a resize never leaves it blank
 last = 0; requestAnimationFrame(step);
  }
  if(window.IntersectionObserver) new IntersectionObserver(function(es){ seen = es[0].isIntersecting; kick(); }).observe(cv);
  sheetImg.onload = function(){ size(); kick(); };
  sheetImg.src = 'demo-tancat.png';
  addEventListener('resize', function(){ size(); kick(); });
  still.addEventListener('change', kick);
  D.addEventListener('visibilitychange', kick);
})();

/* ---------- features: chapter chips ---------- */
var chipLinks = $$('.chips a');
if(chipLinks.length){
  chipLinks.forEach(function(a){ a.addEventListener('click', sweep); });
  if(window.IntersectionObserver){
    var cio = new IntersectionObserver(function(es){
      es.forEach(function(e){ if(!e.isIntersecting) return; chipLinks.forEach(function(a){ a.setAttribute('aria-current', String(a.hash === '#' + e.target.id)); }); });
    }, { rootMargin: '-30% 0px -60% 0px' });
    $$('.chapter').forEach(function(c){ cio.observe(c); });
  }
}

/* ---------- demos ---------- */
function pressOne(group, btn){ $$('[aria-pressed]', group).forEach(function(b){ b.setAttribute('aria-pressed', String(b === btn)); }); }
var DEMOS = {};

DEMOS.cpu = function(el){
  var p = new Pet($('canvas', el), 'dog-jelly', poseFor(42), { scale: 4, group: el });
  var r = $('input', el), out = $('output', el), po = $('#d-cpu-pose');
  function upd(){ var v = +r.value; out.textContent = v; p.setPose(poseFor(v)); po.textContent = P(POSE_NAME[poseFor(v)]); }
  r.addEventListener('input', upd); onLang(upd);
  $$('[data-ch]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); p.setChar(b.dataset.ch); }); });
};

DEMOS.dash = function(el){
  var ul = $('[data-bars]', el), sp = $('[data-speed]', el), btn = $('[data-act=speed]', el.parentNode), res = null;
  function draw(){ ul.innerHTML = barsHTML(); if(res) sp.textContent = res; else if(!btn.disabled) sp.textContent = '-'; }
  onLang(draw);
  btn.addEventListener('click', function(){
    btn.disabled = true; res = null; sp.textContent = L('측정 중…', 'Measuring…');
    setTimeout(function(){
      res = '↓ ' + (380 + Math.round(Math.random() * 140)) + ' · ↑ ' + (80 + Math.round(Math.random() * 40)) + ' Mbps ' + L('(예시)', '(example)');
      sp.textContent = res; btn.disabled = false; say(res);
    }, still.matches ? 300 : 1400);
  });
};

DEMOS.clean = function(el){
  var ITEMS = [[['안 쓰는 앱 종료','Quit unused apps'], ['앱 3개','3 apps'], 0], [['폭주 프로세스','Runaway processes'], ['1개','1'], 0],
    [['로그','Logs'], '120 MB', 0.12], [['앱 캐시','App caches'], '1.4 GB', 1.4], [['npm·Homebrew 캐시','npm and Homebrew caches'], '2.1 GB', 2.1],
    [['오래된 node_modules','Old node_modules'], '3.6 GB', 3.6], [['로그인 항목','Login items'], ['2개 끄기 권장','turn off 2'], 0]];
  var p = new Pet($('canvas', el), 'original-tan-cat', 'lying', { scale: 3, group: el });
  var list = $('[data-list]', el), total = $('[data-total]'.trim(), el.parentNode), btn = $('[data-act=clean]', el.parentNode), toast = $('[data-toast]', el);
  var done = false, on = ITEMS.map(function(){ return true; });
  function sum(){ return ITEMS.reduce(function(s, it, i){ return s + (on[i] ? it[2] : 0); }, 0).toFixed(1); }
  function render(){
    list.innerHTML = done ? '' : ITEMS.map(function(it, i){
      return '<label><input type="checkbox" data-i="' + i + '"' + (on[i] ? ' checked' : '') + '><span>' + P(it[0]) + '</span><b>' + (typeof it[1] === 'string' ? it[1] : P(it[1])) + '</b></label>';
    }).join('');
    total.textContent = done ? L(sum() + ' GB 정리했어요 (예시)', 'Cleared ' + sum() + ' GB (example)') : L('정리할 수 있어요: ' + sum() + ' GB (예시)', 'Ready to clear: ' + sum() + ' GB (example)');
    btn.innerHTML = done ? L('다시 보기', 'Start over') : L('정리하기', 'Clean up');
    toast.textContent = L('저장 안 한 작업은 지켜요', 'Unsaved work stays safe');
  }
  list.addEventListener('change', function(e){ on[+e.target.dataset.i] = e.target.checked; render(); });
  onLang(render);
  btn.addEventListener('click', function(){
    if(done){ done = false; on = on.map(function(){ return true; }); p.setPose('lying'); toast.hidden = true; render(); return; }
    var labels = $$('label', list), k = 0;
    btn.disabled = true;
    labels.forEach(function(lb, i){ if(on[i]) setTimeout(function(){ lb.classList.add('gone'); }, still.matches ? 0 : 90 * k++); });
    setTimeout(function(){
      done = true; render(); btn.disabled = false; toast.hidden = false; p.setPose('special'); say(total.textContent);
      setTimeout(function(){ p.setPose('lying'); toast.hidden = true; }, 2600);
    }, still.matches ? 0 : 90 * k + 260);
  });
};

DEMOS.situ = function(el){
  var p = new Pet($('canvas', el), 'original-tan-cat', 'hungry', { scale: 4, group: el });
  $$('[data-pose]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); p.setPose(b.dataset.pose); }); });
};

DEMOS.meadow = function(el){
  var LINES = { hi: [['헤헤, 불렀어요?','Hehe, you called?'], ['간지러워요','That tickles']], dizzy: [['어질어질…','So dizzy…'], ['세상이 빙글빙글 돌아요','The world is going round and round']],
    pout: [['그만 눌러요, 흥!','Stop poking me, hmph!']] };
  var cv = $('canvas', el), s = $('[data-say]', el), p = new Pet(cv, 'original-tan-cat', 'walk', { scale: 4, group: el });
  var n = 0, lastT = 0, back = 0, cur = null;
  function tap(){
    var t = Date.now(); n = t - lastT < 1200 ? n + 1 : 1; lastT = t;
    var kind = n >= 5 ? 'pout' : n >= 3 ? 'dizzy' : 'hi';
    cur = pick(LINES[kind]); s.textContent = P(cur);
    p.setPose(kind === 'pout' ? 'hungry' : kind === 'dizzy' ? 'special' : 'eat');
    clearTimeout(back); back = setTimeout(function(){ p.setPose('walk'); s.textContent = ''; cur = null; if(kind === 'pout') n = 0; }, 2400);
  }
  cv.addEventListener('click', tap); $('[data-act=tap]', el.parentNode).addEventListener('click', tap);
  onLang(function(){ if(cur) s.textContent = P(cur); });
};

DEMOS.hang = function(el){
  new Pet($('[data-hang]', el), 'dog-jelly', 'slowWalk', { scale: 2, group: el });
  var wc = $('[data-walk]', el), x = 40, target = 40, lastT = 0, rest = 0;
  var p = new Pet(wc, 'cat-tuxedo', 'lying', { scale: 3, group: el, step: function(now){
    var dt = Math.min(0.05, (now - (lastT || now)) / 1000); lastT = now;
    var dx = target - x, ad = Math.abs(dx);
    if(still.matches || ad < 2){ x = target; } else { x += Math.sign(dx) * Math.min(ad, (ad > 120 ? 360 : 140) * dt); }
    if(ad > 2){ p.flip = dx < 0; rest = now; }
    var pose = ad > 120 ? 'run' : ad > 2 ? 'walk' : now - rest > 1500 ? 'lying' : 'slowWalk';
    if(pose !== p.pose) p.setPose(pose);
    if(still.matches && pose === 'slowWalk') p.setPose('lying');
    wc.style.transform = 'translateX(' + Math.round(x) + 'px)';
  }});
  function maxX(){ return el.clientWidth - wc.offsetWidth; }
  function go(v){ target = Math.max(0, Math.min(maxX(), v)); if(still.matches) p.step(performance.now()); wake(); }
  el.addEventListener('pointermove', function(e){ var b = el.getBoundingClientRect(); go(e.clientX - b.left - wc.offsetWidth / 2); });
  el.addEventListener('keydown', function(e){
    if(e.key === 'ArrowLeft' || e.key === 'ArrowRight'){ e.preventDefault(); go(target + (e.key === 'ArrowLeft' ? -60 : 60)); }
  });
  $('[data-act=left]', el.parentNode).addEventListener('click', function(){ go(target - 80); });
  $('[data-act=right]', el.parentNode).addEventListener('click', function(){ go(target + 80); });
  p.step(performance.now());
};

DEMOS.folder = function(el){
  var fold = $('.fold', el), back = $('.back', el), front = $('.front', el);
  function look(k){
    fold.dataset.look = k;
    var cv = k === 'peek' ? back : front, other = k === 'peek' ? front : back;
    other.getContext('2d').clearRect(0, 0, other.width, other.height);
    drawStill(cv, 'dog-jelly', k === 'nap' ? 'lying' : 'walk', 0);
  }
  $$('[data-look]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); look(b.dataset.look); }); });
  look('stand');
};

DEMOS.rug = function(el){
  var rug = $('[data-rug]', el), col = '#F6C9C2', pat = 'character', stamp = 'none';
  var W = 'rgba(255,255,255,.5)';
  var PATS = { character: 'none',
    stripes: 'repeating-linear-gradient(90deg,' + W + ' 0 10px,transparent 10px 22px)',
    checks: 'repeating-linear-gradient(0deg,' + W + ' 0 12px,transparent 12px 24px),repeating-linear-gradient(90deg,' + W + ' 0 12px,transparent 12px 24px)',
    diamonds: 'repeating-linear-gradient(45deg,' + W + ' 0 2px,transparent 2px 16px),repeating-linear-gradient(-45deg,' + W + ' 0 2px,transparent 2px 16px)',
    dots: 'radial-gradient(circle,' + W + ' 0 3px,transparent 3.5px)' };
  function paint(){ rug.style.backgroundColor = col; rug.style.backgroundImage = pat === 'character' ? stamp : PATS[pat];
    rug.style.backgroundSize = pat === 'dots' ? '18px 18px' : pat === 'character' ? 'auto, auto 70%' : ''; rug.style.backgroundRepeat = pat === 'character' ? 'no-repeat' : ''; rug.style.backgroundPosition = pat === 'character' ? 'center' : ''; }
  // 캐릭터 무늬: the chosen character printed big across the rug, washed out so the sleeper on top still reads
  var sc = D.createElement('canvas'); sc.width = 68; sc.height = 40;
  drawStill(sc, 'dog-jelly', 'walk', 0).then(function(){ stamp = 'linear-gradient(rgba(255,255,255,.45),rgba(255,255,255,.45)),url(' + sc.toDataURL() + ')'; paint(); });
  new Pet($('canvas', rug), 'dog-jelly', 'lying', { scale: 3, group: el });
  $$('[data-size]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); rug.style.width = b.dataset.size + '%'; }); });
  $$('[data-pat]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); pat = b.dataset.pat; paint(); }); });
  $$('[data-col]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); col = b.dataset.col; paint(); }); });
  rug.style.width = '55%'; paint();
};

DEMOS.play = function(el){
  var cv = $('canvas', el), g = cv.getContext('2d'), score = $('[data-score]', el.parentNode);
  var GW = 480, GH = 360, floor = 330, plats = [{ x: 60, y: 250, w: 130 }, { x: 290, y: 175, w: 130 }];
  var c = null, me = { x: 40, y: floor, vx: 0, vy: 0, jumps: 0, face: 1, ground: true }, keys = {}, stars = [], got = 0, t0 = performance.now(), running = false, lastT = 0, quietSince = 0;
  sheet('dog-jelly').then(function(s){ c = s; draw(performance.now()); });
  function newStar(){ var spots = [[125, 215], [355, 140], [240, 290], [420, 300], [60, 300], [240, 120]]; var s = pick(spots); return { x: s[0], y: s[1] }; }
  stars = [newStar(), newStar()];
  function caption(){ score.textContent = got ? L('별 ' + got + '개 주웠어요', got + (got > 1 ? ' stars' : ' star') + ' collected') : L('카드를 누르고 ← → 와 스페이스로 별을 주워요.', 'Click the card, then use ← → and Space to catch stars.'); }
  onLang(caption);
  function col(n){ return getComputedStyle(el).getPropertyValue(n).trim(); }
  function jump(){ if(me.ground || me.jumps < 2){ me.vy = -560; me.ground = false; me.jumps++; } go(); }
  function step(now){
    var dt = Math.min(0.033, (now - (lastT || now)) / 1000); lastT = now;
    var dir = (keys.right ? 1 : 0) - (keys.left ? 1 : 0);
    me.vx = dir * 220; if(dir) me.face = dir;
    me.vy += 1500 * dt; me.x = Math.max(0, Math.min(GW - 60, me.x + me.vx * dt));
    var ny = me.y + me.vy * dt; me.ground = false;
    if(me.vy >= 0){
      if(ny >= floor){ ny = floor; me.ground = true; }
      plats.forEach(function(p){ if(me.y <= p.y && ny >= p.y && me.x + 45 > p.x && me.x + 15 < p.x + p.w){ ny = p.y; me.ground = true; } });
    }
    if(me.ground){ me.vy = 0; me.jumps = 0; }
    me.y = ny;
    stars.forEach(function(s, i){ if(Math.abs(s.x - (me.x + 30)) < 30 && Math.abs(s.y - (me.y - 30)) < 34){ got++; stars[i] = newStar(); caption(); } });
    draw(now);
    if(dir || !me.ground) quietSince = now;
    if(now - quietSince > 600 || D.hidden){ running = false; return; }
    requestAnimationFrame(step);
  }
  function go(){ quietSince = performance.now(); if(!running){ running = true; lastT = 0; requestAnimationFrame(step); } }
  function draw(now){
    g.setTransform(cv.width / GW, 0, 0, cv.height / GH, 0, 0); g.imageSmoothingEnabled = false;
    g.clearRect(0, 0, GW, GH);
    g.fillStyle = col('--hair'); g.fillRect(0, floor, GW, GH - floor);
    g.fillStyle = col('--folder'); plats.forEach(function(p){ g.fillRect(p.x, p.y, p.w, 12); });
    g.fillStyle = '#F2C230';
    stars.forEach(function(s){ g.beginPath(); for(var i = 0; i < 10; i++){ var a = Math.PI / 5 * i - Math.PI / 2, r = i % 2 ? 6 : 14; g.lineTo(s.x + Math.cos(a) * r, s.y + Math.sin(a) * r); } g.fill(); });
    if(!c) return;
    var pose = !me.ground ? 'sprint' : me.vx ? 'run' : 'walk', r = row(c, pose);
    var f = still.matches || (me.ground && !me.vx) ? 0 : Math.floor((now - t0) / 1000 / r.s) % r.n;
    drawSprite(g, c, pose, f, 3, me.x - 21, me.y - 60, me.face < 0);
  }
  var KEY = { ArrowLeft: 'left', ArrowRight: 'right' };
  cv.addEventListener('keydown', function(e){
    if(KEY[e.key]){ e.preventDefault(); keys[KEY[e.key]] = true; go(); }
    else if(e.key === ' ' || e.key === 'ArrowUp'){ e.preventDefault(); if(!e.repeat) jump(); }
  });
  cv.addEventListener('keyup', function(e){ if(KEY[e.key]) keys[KEY[e.key]] = false; });
  cv.addEventListener('blur', function(){ keys = {}; });
  cv.addEventListener('pointerdown', function(){ cv.focus(); });
  $$('[data-k]', el.parentNode).forEach(function(b){
    var k = b.dataset.k;
    if(k === 'jump'){ b.addEventListener('click', jump); return; }
    var hold = function(v){ return function(e){ if(e.type === 'pointerdown') e.preventDefault(); keys[k] = v; if(v) go(); }; };
    b.addEventListener('pointerdown', hold(true)); b.addEventListener('pointerup', hold(false)); b.addEventListener('pointerleave', hold(false)); b.addEventListener('pointercancel', hold(false));
    b.addEventListener('click', function(e){ if(e.detail === 0){ keys[k] = true; go(); setTimeout(function(){ keys[k] = false; }, 280); } });   // keyboard press on the button
  });
  new MutationObserver(function(){ draw(performance.now()); }).observe(H, { attributes: true, attributeFilter: ['data-theme'] });
};

DEMOS.fortune = function(el){
  var card = $('[data-card]', el), btn = $('[data-act=redraw]', el.parentNode);
  function render(){
    var r = reading(fortuneDraw), d = new Date();
    card.innerHTML = '<div class="d"><span>' + r.day + '</span><span aria-label="' + r.stars + '/5">' + '★★★★★'.slice(0, r.stars) + '☆☆'.slice(0, 5 - r.stars) + '</span></div>' +
      '<p class="h">' + esc(P(r.head)) + '</p><dl>' + r.areas.map(function(a){ return '<dt>' + P(a[0]) + '</dt><dd>' + esc(P(a[1])) + '</dd>'; }).join('') + '</dl>' +
      '<p class="luck">' + L('행운의 물건: ', 'Lucky item: ') + esc(P(r.item)) + ' · ' + L('행운의 색: ', 'Lucky color: ') + esc(P(r.color)) + '</p>';
  }
  onLang(render);
  btn.addEventListener('click', function(){
    if(fortuneDraw >= 1) return;
    fortuneDraw++; redrawSpent(btn);
    if(still.matches) return render();
    card.classList.remove('flip'); void card.offsetWidth; card.classList.add('flip');
    setTimeout(render, 150); setTimeout(function(){ card.classList.remove('flip'); }, 320);
  });
};

DEMOS.lunch = function(el){
  var CATS = [
    [['한식','Korean'], [['김치찌개','Kimchi stew'],['된장찌개','Soybean paste stew'],['제육볶음','Spicy pork stir-fry'],['비빔밥','Bibimbap'],['순두부찌개','Soft tofu stew'],['불고기','Bulgogi'],['국밥','Rice soup'],['냉면','Cold noodles'],['칼국수','Knife-cut noodles'],['갈비탕','Short rib soup']]],
    [['중식','Chinese'], [['짜장면','Jajangmyeon'],['짬뽕','Jjamppong'],['탕수육','Sweet and sour pork'],['볶음밥','Fried rice'],['마라탕','Malatang'],['마파두부','Mapo tofu'],['울면','Ulmyeon']]],
    [['일식','Japanese'], [['초밥','Sushi'],['라멘','Ramen'],['돈가스','Tonkatsu'],['우동','Udon'],['규동','Gyudon'],['소바','Soba'],['오므라이스','Omurice']]],
    [['양식','Western'], [['파스타','Pasta'],['피자','Pizza'],['햄버거','Burger'],['리조또','Risotto'],['스테이크','Steak'],['샌드위치','Sandwich']]],
    [['분식','Street food'], [['떡볶이','Tteokbokki'],['김밥','Gimbap'],['라볶이','Rabokki'],['순대','Sundae sausage'],['쫄면','Jjolmyeon'],['만두','Dumplings']]],
    [['아시안','Asian'], [['쌀국수','Pho'],['팟타이','Pad thai'],['분짜','Bun cha'],['나시고렝','Nasi goreng'],['카레','Curry'],['반미','Banh mi']]],
    [['샐러드','Salad'], [['닭가슴살 샐러드','Chicken salad'],['포케','Poke'],['연어 샐러드','Salmon salad'],['그릭 샐러드','Greek salad'],['샐러드 랩','Salad wrap']]]];
  var on = CATS.map(function(){ return true; }), reel = $('[data-reel]', el), s = $('[data-say]', el), lever = $('[data-act=pull]', el), cats = $('[data-cats]', el);
  var p = new Pet($('canvas', el), 'dog-shiba', 'hungry', { scale: 2, group: el }), cur = null, busy = false;
  function chips(){
    cats.innerHTML = CATS.map(function(c, i){ return '<button type="button" class="chipb" data-i="' + i + '" aria-pressed="' + on[i] + '">' + P(c[0]) + '</button>'; }).join('');
    reel.textContent = cur ? P(cur) : L('뭐 먹지?', 'What to eat?');
    s.textContent = cur && !busy ? L('오늘 점심은 ' + cur[0] + '! 맛있게 드세요', "Today's lunch is " + cur[1] + '! Enjoy') : '';
  }
  cats.addEventListener('click', function(e){
    var b = e.target.closest('button'); if(!b) return; var i = +b.dataset.i;
    if(on[i] && on.filter(Boolean).length === 1) return;   // keep at least one kind
    on[i] = !on[i]; b.setAttribute('aria-pressed', String(on[i]));
  });
  onLang(chips);
  lever.addEventListener('click', function(){
    if(busy) return;
    var pool = []; CATS.forEach(function(c, i){ if(on[i]) pool = pool.concat(c[1]); });
    var fin = pick(pool.filter(function(m){ return m !== cur; }) .length ? pool.filter(function(m){ return m !== cur; }) : pool);
    s.textContent = ''; p.setPose('hungry');
    function land(){ cur = fin; busy = false; chips(); p.setPose('eat'); say(s.textContent); }
    if(still.matches){ land(); return; }
    busy = true; lever.classList.add('pull'); setTimeout(function(){ lever.classList.remove('pull'); }, 240);
    reel.textContent = L('돌아가는 중…', 'Spinning…');
    [0, 1, 2].forEach(function(k){ setTimeout(function(){ reel.textContent = P(pick(pool)); }, 240 + 120 * k); });
    setTimeout(land, 240 + 360);
  });
};

DEMOS.breath = function(el){
  var ring = $('.ring', el), word = $('[data-word]', el), msg = $('[data-msg]', el), btn = $('[data-act=breath]', el.parentNode);
  var SCENE = { sunset: '#F6D2BC', night: '#232A44', forest: '#D6E6CC' }, iv = 0, start = 0, times = 0, endMsg = null, lastSec = -1;
  var IN = ['들이쉬어요', 'Breathe in'], OUT = ['내쉬어요', 'Breathe out'];
  function idle(){ word.textContent = ''; msg.textContent = endMsg ? P(endMsg) : L('눈을 감고 원을 따라 숨 쉬어요', 'Close your eyes and breathe with the circle'); btn.innerHTML = L('시작', 'Start'); }
  function stop(done){
    clearInterval(iv); iv = 0; el.classList.remove('go');
    if(done){ times++; endMsg = times === 1 ? ['숨 한 번 잘 골랐어요. 어깨가 조금 내려갔죠?', 'Nice breath. Shoulders a little lower now, right?']
      : times === 2 ? ['오늘 두 번째예요. 아까보다 편해 보여요.', 'That\'s two today. You look easier than before.']
      : ['오늘 ' + times + '번째 숨 고르기. 나를 잘 챙기고 있어요!', 'Breather number ' + times + ' today. You\'re taking good care of yourself!']; }
    idle();
  }
  function tickB(){
    var e = (Date.now() - start) / 1000; if(e >= 30) return stop(true);
    var ph = e % 8 < 4 ? IN : OUT, sec = 4 - Math.floor(e % 4);
    word.textContent = P(ph);
    if(still.matches){ if(sec !== lastSec){ lastSec = sec; msg.textContent = P(ph) + ' ' + sec; } }
    else if(msg.dataset.ph !== ph[0]){ msg.dataset.ph = ph[0]; msg.textContent = L('남은 시간 ', 'Time left ') + Math.ceil(30 - e) + L('초', 's'); }
  }
  btn.addEventListener('click', function(){
    if(iv) return stop(false);
    endMsg = null; start = Date.now(); lastSec = -1; msg.dataset.ph = ''; el.classList.remove('go'); void el.offsetWidth; el.classList.add('go');
    btn.innerHTML = L('그만', 'Stop'); tickB(); iv = setInterval(tickB, 200);
  });
  $$('[data-scene]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); el.style.background = SCENE[b.dataset.scene]; el.classList.toggle('night', b.dataset.scene === 'night'); }); });
  onLang(function(){ if(iv){ btn.innerHTML = L('그만', 'Stop'); msg.dataset.ph = ''; tickB(); } else idle(); });
};

DEMOS.sticky = function(el){
  var p = new Pet($('canvas', el), 'dog-jelly', 'lying', { scale: 3, group: el }), ta = $('textarea', el), note = $('.pnote', el), t = 0;
  ta.addEventListener('input', function(){ p.setPose('fastWalk'); clearTimeout(t); t = setTimeout(function(){ p.setPose('lying'); }, 1500); });
  $$('[data-col]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); note.style.background = b.dataset.col; }); });
};

DEMOS.nearby = function(el){
  var me = new Pet($('[data-me]', el), 'dog-jelly', 'lying', { scale: 3, group: el });
  var you = new Pet($('[data-you]', el), 'cat-tuxedo', 'lying', { scale: 3, group: el });
  you.flip = true;
  var sMe = $('[data-say=me]', el), sYou = $('[data-say=you]', el), cMe = $('[data-me]', el), cYou = $('[data-you]', el);
  var line = ['오늘은 칼퇴 각, 다들 화이팅', 'Leaving on time today, hang in there everyone'], mine = null, last = null, back = 0;
  var pline = $('[data-pline]', el), input = $('[data-line]', el);
  function showLine(){ pline.textContent = mine || P(line); }
  function talk(){ if(!last) return; sMe.textContent = P(last[0]); sYou.textContent = P(last[1]); }
  function emote(kind){
    clearTimeout(back);
    var heart = '<svg width="12" height="12" viewBox="0 0 6 6" aria-hidden="true" style="display:inline-block;vertical-align:-1px;margin-left:4px"><path d="M1 0h1v1h2V0h1v1h1v2H5v1H4v1H2V4H1V3H0V1h1z" fill="#E0577A"/></svg>';
    if(kind === 'kiss'){ last = [['다같이 뽀뽀!','Group kiss!'], ['다같이 뽀뽀!','Group kiss!']]; me.setPose('eat'); you.setPose('eat');
      if(!still.matches){ cMe.style.transform = 'translateX(14px)'; cYou.style.transform = 'translateX(-14px)'; } }
    if(kind === 'poop'){ last = [['다같이 똥!','Group poop!'], ['다같이 똥!','Group poop!']]; me.setPose('hungry'); you.setPose('hungry'); }
    if(kind === 'toss'){ last = [['던지기','Toss'], ['날아왔어!','I got tossed over!']]; me.setPose('run'); you.setPose('sprint');
      if(!still.matches) cYou.style.transform = 'translate(-40px,-46px) rotate(-24deg)'; setTimeout(function(){ cYou.style.transform = ''; }, 420); }
    talk(); if(kind === 'kiss'){ sMe.innerHTML += heart; sYou.innerHTML += heart; }
    say(P(last[1]));
    back = setTimeout(function(){ me.setPose('lying'); you.setPose('lying'); cMe.style.transform = cYou.style.transform = ''; last = null; sMe.textContent = mine || ''; sYou.textContent = ''; }, 1900);
  }
  $$('[data-emote]', el).forEach(function(b){ b.addEventListener('click', function(){ emote(b.dataset.emote); }); });
  function save(){ var v = input.value.trim().slice(0, 40); if(!v) return; mine = v; sMe.textContent = v; showLine(); say(v); }
  $('[data-act=line]', el).addEventListener('click', save);
  input.addEventListener('keydown', function(e){ if(e.key === 'Enter'){ e.preventDefault(); save(); } });
  var pc = $('[data-pcard]', el);
  pc.addEventListener('click', function(){ var on = !pc.classList.contains('on'); pc.classList.toggle('on', on); pc.setAttribute('aria-pressed', String(on)); });
  onLang(function(){ showLine(); talk(); });
};

DEMOS.office = function(el){
  var ST = [['근무 중','Working'], ['회의','Meeting'], ['집중','Focus'], ['자리 비움','Away'], ['식사','Meal'], ['퇴근','Off work'], ['퇴근한 척','Pretending I left']];
  var DESKS = [{ n: ['나','Me'], ch: 'dog-jelly', st: 0, me: true }, { n: ['시바','Shiba'], ch: 'dog-shiba', st: 1 }, { n: ['턱시도','Tuxedo'], ch: 'cat-tuxedo', st: 2 }, { n: ['AI 팀원','AI teammate'], ch: 'original-tan-cat', st: -1 }];
  var box = $('[data-desks]', el), open = {};
  function render(){
    box.innerHTML = DESKS.map(function(d, i){
      var st = d.st < 0 ? L('연결 안 됨', 'Not connected') : P(ST[d.st]);
      return '<button type="button" data-i="' + i + '" aria-label="' + esc(P(d.n) + ', ' + st) + '"><span class="st"' + (open[i] ? '' : ' hidden') + '>' + esc(st) + '</span><canvas class="spr" width="68" height="40" aria-hidden="true"></canvas><span>' + esc(P(d.n)) + '</span></button>';
    }).join('');
    $$('canvas', box).forEach(function(cv, i){ drawStill(cv, DESKS[i].ch, DESKS[i].st === 5 ? 'lying' : 'walk', 0); });
  }
  box.addEventListener('click', function(e){
    var b = e.target.closest('button'); if(!b) return; var i = +b.dataset.i, d = DESKS[i];
    if(d.me && open[i]) d.st = (d.st + 1) % ST.length; else open[i] = !open[i];
    render(); var nb = $('[data-i="' + i + '"]', box); nb.focus(); say(nb.getAttribute('aria-label'));
  });
  onLang(render);
};

DEMOS.ai = function(el){
  var QS = [
    { q: ['다운로드 폴더 정리해 줘', 'Tidy up my Downloads folder'], a: ['다운로드 폴더에서 30일 넘은 설치 파일 12개를 찾았어요 (예시).', 'I found 12 installer files older than 30 days in Downloads (example).'], act: ['설치 파일 12개를 휴지통으로 옮길까요?', 'Move the 12 installers to the Trash?'] },
    { q: ['3시 회의 알림 맞춰 줘', 'Remind me about the 3 p.m. meeting'], a: ['오늘 오후 3시에 알려 드릴게요.', "I'll remind you today at 3 p.m."], act: ['오후 2시 55분에 알림을 만들까요?', 'Create a reminder for 2:55 p.m.?'] },
    { q: ['지금 맥이 왜 느려?', 'Why is my Mac slow?'], a: ['브라우저 탭 하나가 CPU를 많이 쓰고 있어요 (예시). 클리너에서 정리할 수 있어요.', 'One browser tab is using a lot of CPU (example). The Cleaner can take care of it.'], act: null }];
  var chat = $('[data-chat]', el), qs = $('[data-qs]', el);
  function chips(){ chat.innerHTML = '<p class="a">' + L('무엇을 도와드릴까요? 아래 질문을 눌러 보세요.', 'What can I help with? Tap a question below.') + '</p>'; qs.innerHTML = QS.map(function(x, i){ return '<button type="button" class="chipb" data-i="' + i + '">' + esc(P(x.q)) + '</button>'; }).join(''); }
  qs.addEventListener('click', function(e){
    var b = e.target.closest('button'); if(!b) return; var x = QS[+b.dataset.i];
    chat.innerHTML = '<p class="q">' + esc(P(x.q)) + '</p><p class="a">' + esc(P(x.a)) + '</p>' + (x.act ? '<div class="confirm"><span>' + esc(P(x.act)) + '</span><span class="r"><button type="button" class="act ghost" data-c="no">' + L('취소', 'Cancel') + '</button><button type="button" class="act" data-c="yes">' + L('실행', 'Run') + '</button></span></div>' : '');
  });
  chat.addEventListener('click', function(e){
    var b = e.target.closest('[data-c]'); if(!b) return;
    var c = b.closest('.confirm'), p = D.createElement('p'); p.className = 'a';
    p.textContent = b.dataset.c === 'yes' ? L('실행했어요(데모)', 'Done (demo)') : L('취소했어요', 'Cancelled');
    c.replaceWith(p);
  });
  onLang(chips);
};

DEMOS.gpets = function(el){
  var box = $('[data-gpets]', el);
  [['dog-jelly','젤리','Jelly'], ['dog-shiba','시바견','Shiba Inu'], ['cat-cheese-tabby','치즈 태비','Orange Tabby'], ['cat-tuxedo','턱시도','Tuxedo'], ['original-tan-cat','태닝 고양이','Tanned Cat']].forEach(function(x){
    var cv = D.createElement('canvas'); cv.width = 96; cv.height = 104; cv.setAttribute('role', 'img'); cv.dataset.labelEn = x[2]; cv.setAttribute('aria-label', x[1]);
    box.appendChild(cv); new Pet(cv, gptSheet(x[0]), 'run', { scale: 0.5, group: el });
  });
  applyAttrs();
};

DEMOS.choose = function(el){
  var big = new Pet($('[data-big]', el), 'dog-jelly', 'run', { scale: 4, group: el }), grid = $('[data-grid]', el), name = $('[data-name]', el), cur = 'dog-jelly', M = null;
  index().then(function(m){
    M = m;
    grid.innerHTML = m._order.map(function(id){ return '<button type="button" data-id="' + id + '" aria-pressed="' + (id === cur) + '" aria-label="' + esc(m[id].name.ko) + '" data-label-en="' + esc(m[id].name.en) + '"><canvas width="34" height="20"></canvas></button>'; }).join('');
    applyAttrs();
    $$('canvas', grid).forEach(function(cv, i){ drawStill(cv, m._order[i], 'walk', 0); });
    showName();
  });
  function showName(){ if(M) name.textContent = L(M[cur].name.ko, M[cur].name.en); }
  grid.addEventListener('click', function(e){ var b = e.target.closest('button'); if(!b) return; cur = b.dataset.id; pressOne(grid, b); big.setChar(cur); showName(); });
  onLang(showName);
};

/* ---------- 3.4 ---------- */
DEMOS.hotkeys = function(el){
  var scr = $('.hk', el), fr = $('[data-friends]', el), log = $('[data-log]', el), dot = $('[data-dot]', el), cvs = $$('canvas', fr);
  new Pet(cvs[0], 'dog-jelly', 'slowWalk', { scale: 2, group: el }); new Pet(cvs[1], 'cat-tuxedo', 'lying', { scale: 2, group: el });
  var LINES = [['점심 뭐 먹지?', "What's for lunch?"], ['3시 회의 잊지 마요', "Don't forget the 3 p.m. meeting"]], st = { friends: false, quiet: false, recent: false };
  function render(){
    $$('[data-say]', el).forEach(function(s, i){ s.textContent = P(LINES[i]); });
    fr.classList.toggle('off', st.friends); scr.classList.toggle('hush', st.quiet); dot.hidden = !st.quiet; log.hidden = !st.recent;
    log.innerHTML = '<b>' + L('대화 모아보기', 'Chat roundup') + '</b>' + LINES.map(function(l, i){ return esc((i ? L('턱시도', 'Tuxedo') : L('젤리', 'Jelly')) + ': ' + P(l)); }).join('<br>');
    $$('[data-hk]', el).forEach(function(b){ b.setAttribute('aria-pressed', String(st[b.dataset.hk])); });
  }
  var MSG = { friends: [['데스크톱 친구들을 숨겼어요', 'Desktop friends hidden'], ['데스크톱 친구들이 돌아왔어요', 'Desktop friends are back']],
    quiet: [['쉿 모드를 켰어요. 읽지 않은 메시지는 메뉴에 점으로 남아요', 'Hush mode on. Unread messages stay as a dot in the menu'], ['쉿 모드를 껐어요', 'Hush mode off']] };
  function hit(k){ st[k] = !st[k]; render(); if(MSG[k]) say(P(MSG[k][st[k] ? 0 : 1])); }
  $$('[data-hk]', el).forEach(function(b){ b.addEventListener('click', function(){ hit(b.dataset.hk); }); });
  var KEYS = { KeyD: 'friends', KeyQ: 'quiet', KeyL: 'recent' };
  scr.addEventListener('keydown', function(e){ var k = KEYS[e.code]; if(k && e.ctrlKey && e.altKey && e.shiftKey){ e.preventDefault(); hit(k); } });
  onLang(render);
};

DEMOS.draw = function(el){
  var NAMES = [['젤리','Jelly'], ['시바','Shiba'], ['턱시도','Tuxedo'], ['치즈냥','Orange tabby']];
  var list = $('[data-list]', el), s = $('[data-say]', el), btn = $('[data-act=draw]', el.parentNode), mode = 'roulette', res = -1, busy = false;
  var DONE = { roulette: ['룰렛이 멈췄어요: ', 'The roulette stopped: '], ladder: ['사다리를 타고 내려왔어요: ', 'Down the ladder: '], lots: ['제비를 뽑았어요: ', 'Lot drawn: '] };
  function render(on){
    list.innerHTML = NAMES.map(function(n, i){ return '<span' + (i === on ? ' class="on"' : '') + '>' + esc(P(n)) + '</span>'; }).join('');
    s.textContent = res >= 0 && !busy ? P(DONE[mode]) + L(NAMES[res][0] + ' 당첨!', NAMES[res][1] + ' wins!') : '';
  }
  $$('[data-mode]', el).forEach(function(b){ b.addEventListener('click', function(){ pressOne(b.parentNode, b); mode = b.dataset.mode; res = -1; render(-1); }); });
  btn.addEventListener('click', function(){
    if(busy) return;
    var fin = Math.floor(Math.random() * NAMES.length);
    if(still.matches){ res = fin; render(fin); say(s.textContent); return; }
    busy = true; btn.disabled = true;
    var hops = 8 + fin + Math.floor(Math.random() * 2) * NAMES.length, k = 0;   // lands on fin
    (function hop(){
      render(k % NAMES.length);
      if(k >= hops){ busy = false; btn.disabled = false; res = fin; render(fin); say(s.textContent); return; }
      k++; setTimeout(hop, 60 + k * 14);
    })();
  });
  onLang(function(){ render(res); });
};

DEMOS.drift = function(el){
  var card = $('[data-card]', el), cat = $('[data-cat]', el), doc = $('[data-doc]', el), vid = $('[data-vid]', el), btn = $('[data-act=drift]', el.parentNode);
  var p = new Pet($('canvas', cat), 'cat-cheese-tabby', 'lying', { scale: 3, group: el });
  var PAW = 3000, phase = 'idle', t1 = 0, t2 = 0, shown = null;
  var DOC = ['문서', 'Docs'], VID = ['영상 사이트', 'Video site'];
  var CARDS = {
    idle: [['딴짓 6분을 눌러 보세요.', 'Press "6 minutes of drift".'], []],
    nudge: [['아까 문서 하던 중이었죠. 돌아갈까요?', 'You were working in Docs a moment ago. Head back?'], [['back', '돌아가기', 'Go Back', 1], ['rest', '쉬는 중', 'Taking a Break'], ['not', '딴짓 아님', 'Not Drifting']]],
    still: [['잡혔다! 그대로 둘게요. 아직 딴짓 중이에요?', "Caught! I'll leave it open. Still drifting?"], [['done', '네, 계속 봐 줘요', 'Yes, Keep Watching', 1], ['done', '아니요, 일하는 중', "No, I'm Working"]]],
    closed: [['영상 사이트 탭은 냥펀치로 닫았어요. 문서 화면으로 돌아왔어요.', "I swatted the video site's tab closed. You're back in Docs."], [['done', '알겠어요', 'Got It', 1]]],
    rest: [['10분 동안은 안 물어볼게요. (쉬는 중은 10분·20분)', "I won't ask for 10 minutes. (Breaks are 10 or 20 min)"], [['done', '알겠어요', 'Got It', 1]]],
    not: [['영상 사이트를 집중 목록에 넣었어요.', 'The video site is on the focus list now.'], [['done', '알겠어요', 'Got It', 1]]] };
  function show(k){
    shown = k; var c = CARDS[k];
    card.classList.toggle('idle', k === 'idle');
    card.innerHTML = (k === 'idle' ? '' : '<span class="who">' + L('딴짓 지킴이', 'Drift Guard') + '</span>') + '<p>' + esc(P(c[0])) + '</p>' +
      (c[1].length ? '<div class="r">' + c[1].map(function(b){ return '<button type="button" data-b="' + b[0] + '"' + (b[3] ? ' class="go"' : '') + '>' + esc(L(b[1], b[2])) + '</button>'; }).join('') + '</div>' : '');
  }
  function titles(){ $('[data-doct]', el).textContent = P(DOC); $('[data-vidt]', el).textContent = P(VID); }
  function catAt(x){ cat.style.transform = 'translateX(' + Math.round(x) + 'px)'; }
  function winX(){ return vid.offsetLeft + vid.offsetWidth / 2 - cat.offsetWidth / 2; }
  function clear(){ clearTimeout(t1); clearTimeout(t2); cat.classList.remove('up', 'slam', 'caught'); cat.disabled = true; }
  function reset(){
    clear(); phase = 'idle'; catAt(0); p.flip = false; p.setPose('lying');
    vid.classList.remove('gone'); vid.classList.add('front'); doc.classList.remove('front'); btn.disabled = false; show('idle');
  }
  function leave(k){ clear(); phase = 'idle'; p.flip = true; p.setPose('run'); catAt(0); t1 = setTimeout(function(){ p.flip = false; p.setPose('lying'); }, still.matches ? 0 : 700); show(k); }
  btn.addEventListener('click', function(){
    if(phase !== 'idle') return;
    reset(); phase = 'run'; btn.disabled = true; show('nudge'); p.setPose('run'); catAt(winX());
    t1 = setTimeout(function(){
      phase = 'raised'; p.setPose('walk'); cat.disabled = false; cat.style.setProperty('--paw', PAW + 'ms'); cat.classList.add('up');
      say(L('고양이가 앞발을 들었어요. 3초 안에 눌러요', 'The cat lifted its paw. Click it within 3 seconds'));
      t2 = setTimeout(function(){
        phase = 'slammed'; cat.disabled = true; cat.classList.remove('up'); cat.classList.add('slam'); vid.classList.add('gone'); doc.classList.add('front');
        show('closed'); say(P(CARDS.closed[0]));
        t1 = setTimeout(function(){ leave('closed'); btn.disabled = false; }, 900);
      }, PAW);
    }, still.matches ? 0 : 750);
  });
  cat.addEventListener('click', function(){
    if(phase !== 'raised' && phase !== 'run') return;
    clear(); phase = 'caught'; cat.classList.add('caught'); p.setPose('hungry'); show('still'); say(P(CARDS.still[0]));
  });
  card.addEventListener('click', function(e){
    var b = e.target.closest('[data-b]'); if(!b) return; var k = b.dataset.b;
    if(k === 'back'){ leave('idle'); doc.classList.add('front'); btn.disabled = false; say(L('문서로 돌아갔어요', 'Back in Docs')); return; }
    if(k === 'rest' || k === 'not'){ leave(k); btn.disabled = false; return; }
    reset();
  });
  onLang(function(){ titles(); show(shown || 'idle'); });
};

DEMOS.throw = function(el){
  var ITEMS = [['귤','Tangerine','#F29A2E'], ['베개','Pillow','#F4F0EA'], ['양말','Sock','#7FA7D9'], ['종이 뭉치','Paper ball','#E6E1D8']];
  var stage = $('[data-stage]', el), item = $('[data-item]', el), you = $('.you', el), s = $('[data-say]', el), cap = $('[data-cap]', el.parentNode), dots = $$('[data-hits] i', el);
  var me = new Pet($('.me', el), 'dog-jelly', 'walk', { scale: 3, group: el }), fr = new Pet(you, 'cat-tuxedo', 'walk', { scale: 3, group: el });
  fr.flip = true;
  var cur = 0, hits = [], ko = 0, flying = false, back = 0;
  var box = $('[data-items]', el);
  function chips(){ box.innerHTML = ITEMS.map(function(it, i){ return '<button type="button" class="chipb" data-i="' + i + '" aria-pressed="' + (i === cur) + '">' + esc(L(it[0], it[1])) + '</button>'; }).join(''); }
  function caption(){ cap.textContent = ko ? L('기절! 6초 뒤에 깨어나요', 'Knocked out! Back up in 6 seconds') : L('10초 안에 ' + hits.length + '/5번 맞혔어요', hits.length + '/5 hits in 10 seconds'); dots.forEach(function(d, i){ d.classList.toggle('on', i < hits.length); }); }
  box.addEventListener('click', function(e){ var b = e.target.closest('button'); if(!b) return; cur = +b.dataset.i; pressOne(box, b); });
  function land(){
    flying = false; item.style.opacity = 0; if(ko) return;
    var now = Date.now(); hits = hits.filter(function(t){ return now - t < 10000; }); hits.push(now);
    fr.setPose('hungry'); s.textContent = L('아야!', 'Ouch!'); clearTimeout(back);
    if(hits.length >= 5){
      ko = setTimeout(function(){ ko = 0; hits = []; stage.classList.remove('ko'); fr.setPose('walk'); s.textContent = ''; caption(); }, 6000);
      stage.classList.add('ko'); fr.setPose('exhausted'); s.textContent = L('젤리에게 맞아서 기절!', 'Knocked out by Jelly!'); say(s.textContent);
    } else back = setTimeout(function(){ if(!ko){ fr.setPose('walk'); s.textContent = ''; } }, 900);
    caption();
  }
  function toss(){
    if(flying || ko) return;
    flying = true; me.setPose('run'); setTimeout(function(){ me.setPose('walk'); }, 400);
    item.style.background = ITEMS[cur][2];
    var dx = you.offsetLeft - item.offsetLeft + 40;
    if(still.matches || !item.animate){ land(); return; }
    item.animate([{ opacity: 1, transform: 'translate(0,0)' }, { opacity: 1, transform: 'translate(' + dx / 2 + 'px,-70px) rotate(180deg)' }, { opacity: 1, transform: 'translate(' + dx + 'px,10px) rotate(360deg)' }],
      { duration: 520, easing: 'linear' }).onfinish = land;
  }
  you.addEventListener('click', toss); $('[data-act=throw]', el.parentNode).addEventListener('click', toss);
  onLang(function(){ chips(); caption(); if(s.textContent) s.textContent = ko ? L('젤리에게 맞아서 기절!', 'Knocked out by Jelly!') : L('아야!', 'Ouch!'); });
};

DEMOS.seats = function(el){
  var scr = $('[data-scr]', el), row = $$('.row canvas', el);
  [['dog-jelly','slowWalk'], ['cat-tuxedo','lying'], ['dog-shiba','walk']].forEach(function(c, i){ new Pet(row[i], c[0], c[1], { scale: 2, group: el }); });
  new Pet($('canvas.hang', el), 'cat-cheese-tabby', 'hungry', { scale: 2, group: el });
  new Pet($('.chair canvas', el), 'dog-corgi', 'lying', { scale: 2, group: el });
  $$('[data-edge]', el).forEach(function(b){ if(b === scr) return; b.addEventListener('click', function(){ pressOne(b.parentNode, b); scr.dataset.edge = b.dataset.edge; }); });
  $$('[data-tog]', el).forEach(function(b){ b.addEventListener('click', function(){
    var on = b.getAttribute('aria-pressed') !== 'true'; b.setAttribute('aria-pressed', String(on));
    $$('[data-' + b.dataset.tog + ']', scr).forEach(function(x){ x.hidden = !on; });
  }); });
};

DEMOS.meet = function(el){
  var cvs = $$('canvas', el), says = $$('[data-say]', el);
  [['dog-shiba','walk'], ['cat-cheese-tabby','slowWalk'], ['dog-corgi','lying']].forEach(function(c, i){ new Pet(cvs[i], c[0], c[1], { scale: 2, group: el }); });
  var LINES = [['오늘 회식 장소 정했어요?', 'Did we pick a place for dinner?'], ['퇴근까지 한 시간!', 'One hour till home time!']];
  onLang(function(){ says[0].textContent = P(LINES[0]); says[2].textContent = P(LINES[1]); });
};

DEMOS.season = function(el){
  var ITEMS = [['귀마개','Earmuffs'], ['눈송이 털모자','Snowflake beanie'], ['사슴뿔','Antlers'], ['별 안경','Star glasses'], ['체크 목도리','Check scarf'], ['방울 목걸이','Bell necklace'],
    ['눈꽃 셔츠','Snowflake shirt'], ['솔잎 셔츠','Pine shirt'], ['산딸기 셔츠','Raspberry shirt'], ['눈빛 말풍선','Snow bubble'], ['솔잎 말풍선','Pine bubble'], ['산딸기 말풍선','Raspberry bubble']];
  var board = $('[data-board]', el), tk = $('[data-tickets]', el), cells, open, tickets;
  function deal(){
    cells = ITEMS.concat([0, 0, 0, 0].map(function(){ return null; }));   // 16 cells: 12 items, 4 of 8 coins (season.json)
    for(var i = cells.length - 1; i > 0; i--){ var j = Math.floor(Math.random() * (i + 1)), t = cells[i]; cells[i] = cells[j]; cells[j] = t; }
    open = cells.map(function(){ return false; }); tickets = 2; render();
  }
  function label(i){ return cells[i] ? P(cells[i]) : L('코인 8개', '8 coins'); }
  function render(){
    board.innerHTML = cells.map(function(c, i){
      return '<button type="button" data-i="' + i + '"' + (open[i] ? ' class="open' + (c ? '' : ' coin') + '" aria-disabled="true"' : ' aria-label="' + esc(L((i + 1) + '번 종이', 'Paper ' + (i + 1))) + '"') + '>' + (open[i] ? esc(label(i)) : i + 1) + '</button>';
    }).join('');
    tk.textContent = tickets ? L('오늘 뽑기권 ' + tickets + '장 (예시)', tickets + (tickets > 1 ? ' tickets' : ' ticket') + ' today (example)') : L('뽑기권은 내일 또 2장 와요', 'Two more tickets come tomorrow');
  }
  board.addEventListener('click', function(e){
    var b = e.target.closest('button'); if(!b) return; var i = +b.dataset.i;
    if(open[i] || !tickets) return;
    tickets--; open[i] = true; render(); say(label(i)); var nb = $('[data-i="' + i + '"]', board); if(nb) nb.focus();
  });
  $('[data-act=season]', el.parentNode).addEventListener('click', deal);
  deal(); onLang(render);
};

var demoIO = window.IntersectionObserver ? new IntersectionObserver(function(es){
  es.forEach(function(e){ if(e.isIntersecting){ demoIO.unobserve(e.target); start(e.target); } });
}, { rootMargin: '200px 0px' }) : null;
function start(el){ var f = DEMOS[el.dataset.demo]; if(f && !el._on){ el._on = true; try{ f(el); }catch(err){ if(window.console) console.error(err); } } }
$$('[data-demo]').forEach(function(el){ if(demoIO) demoIO.observe(el); else start(el); });
})();
