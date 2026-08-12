(function(){
 const slots={
  socialbar:{src:'https://pl30793531.effectivecpmnetwork.com/f7/43/10/f743103a2ead29906ca081e7239f2d7d.js'},
  popunder:{src:'https://pl30793530.effectivecpmnetwork.com/7c/e6/53/7ce65317b3e0c7615d26a768f5ec2c69.js'},
  banner300:{src:'https://www.highperformanceformat.com/19f1a40144737b7ed8ca43e7616c64f5/invoke.js',at:{key:'19f1a40144737b7ed8ca43e7616c64f5',format:'iframe',height:250,width:300,params:{}}},
  banner320:{src:'https://www.highperformanceformat.com/8455c2cc71e7feadc0f131a93a3e6ef0/invoke.js',at:{key:'8455c2cc71e7feadc0f131a93a3e6ef0',format:'iframe',height:50,width:320,params:{}}},
  banner728:{src:'https://www.highperformanceformat.com/2a4983c6cf6189d3cacb8e5f9a92246d/invoke.js',at:{key:'2a4983c6cf6189d3cacb8e5f9a92246d',format:'iframe',height:90,width:728,params:{}}}
 };
 function load(el){return new Promise(resolve=>{const key=el.dataset.adSlot,def=slots[key];if(!def){resolve(false);return}const s=document.createElement('script');s.async=true;s.src=def.src;s.onload=()=>resolve(true);s.onerror=()=>resolve(false);if(def.at)window.atOptions=def.at;el.appendChild(s)})}
 async function init(){for(const el of document.querySelectorAll('[data-ad-slot]'))await load(el)}
 window.PakCashAds={provider:'Configured third-party provider',load,slots};
 document.addEventListener('DOMContentLoaded',init);
})();
