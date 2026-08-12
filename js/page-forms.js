(function(){
 const $=id=>document.getElementById(id);
 function msg(text,kind){const e=$('msg');if(e){e.textContent=text;e.className='form-msg '+kind}}
 function setBusy(btn,busy,label){if(!btn)return;btn.disabled=busy;if(busy){btn.dataset.label=btn.textContent;btn.textContent=label}else btn.textContent=btn.dataset.label||btn.textContent}
 async function initRegister(){
  const form=$('registerForm');if(!form)return;if(window.pakcashConfigError||!window.pakcashSupabase){msg('The site is temporarily unavailable.','error');return;}
  const referral=$('referral'),fromUrl=new URLSearchParams(location.search).get('ref');if(fromUrl&&/^[A-Za-z0-9]{10}$/.test(fromUrl)){referral.value=fromUrl.toUpperCase();}
  const session=await window.pakcashGetSession();if(session){location.replace('/index.html');return}
  form.addEventListener('submit',async e=>{e.preventDefault();
   const u=$('username').value.trim(),em=$('email').value.trim().toLowerCase(),pw=$('password').value,cf=$('confirm').value,ref=referral.value.trim().toUpperCase(),btn=$('registerBtn');
   if(!/^[A-Za-z0-9_]{3,30}$/.test(u))return msg('Username must be 3–30 letters, numbers or underscore.','error');
   if(pw.length<10)return msg('Password must contain at least 10 characters.','error');
   if(pw!==cf)return msg('Passwords do not match.','error');
   if(ref&&!/^PK[A-Z0-9]{8}$/.test(ref))return msg('Referral code is invalid.','error');
   setBusy(btn,true,'Creating account…');
   try{
    const {data,error}=await window.pakcashSupabase.auth.signUp({email:em,password:pw,options:{data:{username:u,referral_code:ref||null}}});
    if(error)throw error;
    if(data.session){location.replace('/index.html');return}
    msg('Account created. Check your email to confirm your account, then log in.','success');
   }catch(err){let text='Registration could not be completed. Please check your details and try again.';if(/already registered|already exists|duplicate/i.test(err.message||''))text='That email or username is already in use.';if(/referral code/i.test(err.message||''))text='That referral code is invalid or unavailable.';msg(text,'error')}
   finally{setBusy(btn,false)}
  });
 }
 async function initLogin(){
  const form=$('loginForm');if(!form)return;if(window.pakcashConfigError||!window.pakcashSupabase){msg('The site is temporarily unavailable.','error');return;}const existing=await window.pakcashGetSession();if(existing){location.replace('/index.html');return}
  const params=new URLSearchParams(location.search),error=params.get('error');if(error==='account')msg('This account is suspended or closed.','error');else if(error==='profile')msg('Your account profile could not be verified. Please contact support.','error');else if(error==='config')msg('The site is temporarily unavailable.','error');
  form.addEventListener('submit',async e=>{e.preventDefault();const btn=$('loginBtn');setBusy(btn,true,'Signing in…');try{const {error}=await window.pakcashSupabase.auth.signInWithPassword({email:$('email').value.trim().toLowerCase(),password:$('password').value});if(error)throw error;const session=await window.pakcashRequireAuth();if(session)location.replace('/index.html');}catch(err){msg('Invalid email or password.','error')}finally{setBusy(btn,false)}});
 }
 async function initRecovery(){const form=$('recoveryForm');if(!form)return;if(window.pakcashConfigError||!window.pakcashSupabase){msg('The site is temporarily unavailable.','error');return;}form.addEventListener('submit',async e=>{e.preventDefault();const btn=form.querySelector('button');setBusy(btn,true,'Sending…');try{const {error}=await window.pakcashSupabase.auth.resetPasswordForEmail($('email').value.trim().toLowerCase(),{redirectTo:location.origin+'/reset-password.html'});if(error)throw error;msg('If an account exists for that email, a recovery email has been sent.','success')}catch(err){msg('We could not start password recovery. Please try again.','error')}finally{setBusy(btn,false)}})}
 async function initReset(){const form=$('resetForm');if(!form)return;if(window.pakcashConfigError||!window.pakcashSupabase){msg('The site is temporarily unavailable.','error');return;}const session=await window.pakcashGetSession();if(!session){msg('Open this page from the password recovery email.','error');return}form.addEventListener('submit',async e=>{e.preventDefault();const pw=$('password').value,cf=$('confirm').value,btn=form.querySelector('button');if(pw.length<10||pw!==cf){msg('Passwords must match and contain at least 10 characters.','error');return}setBusy(btn,true,'Updating…');try{const {error}=await window.pakcashSupabase.auth.updateUser({password:pw});if(error)throw error;msg('Password updated. You can now log in.','success');setTimeout(()=>location.replace('/login.html'),1000)}catch(err){msg('Password could not be updated. Please reopen the recovery email and try again.','error')}finally{setBusy(btn,false)}})}
 document.addEventListener('DOMContentLoaded',()=>{initRegister();initLogin();initRecovery();initReset()});
})();
