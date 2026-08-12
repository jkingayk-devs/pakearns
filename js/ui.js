(function(){
 function init(){
  document.querySelectorAll('.nav-toggle').forEach(btn=>btn.addEventListener('click',()=>{const nav=btn.parentElement.querySelector('.nav');const open=nav.classList.toggle('open');btn.setAttribute('aria-expanded',String(open));}));
  document.addEventListener('click',async e=>{
   document.querySelectorAll('.nav.open').forEach(nav=>{if(!nav.parentElement.contains(e.target)){nav.classList.remove('open');const b=nav.parentElement.querySelector('.nav-toggle');if(b)b.setAttribute('aria-expanded','false')}});
   const action=e.target.closest('[data-action]')?.dataset.action;if(!action)return;
   if(action==='logout')window.pakcashSignOut();
   if(action==='share-referral')window.pakcashShareReferral();
   if(action==='copy-referral')window.pakcashCopyReferral();
  });
  window.addEventListener('pakcash:error',e=>showToast(e.detail,'error'));window.addEventListener('pakcash:success',e=>showToast(e.detail,'success'));
 }
 function showToast(text,type){let box=document.getElementById('toast');if(!box){box=document.createElement('div');box.id='toast';box.className='toast';document.body.appendChild(box)}box.textContent=text;box.className='toast '+type;clearTimeout(window.__toast);window.__toast=setTimeout(()=>box.className='toast',4500)}
 document.addEventListener('DOMContentLoaded',init);
})();
