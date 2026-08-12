(function(){
 const url=window.PAKCASH_SUPABASE_URL,key=window.PAKCASH_SUPABASE_ANON_KEY;
 if(!url||!key||url.includes("YOUR_PROJECT")||key.includes("YOUR_SUPABASE")){window.pakcashConfigError=true;return;}
 window.pakcashSupabase=window.supabase.createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
})();
window.pakcashGetSession=async function(){const sb=window.pakcashSupabase;if(!sb)return null;const {data}=await sb.auth.getSession();return data.session||null};
window.pakcashRequireAuth=async function(){const sb=window.pakcashSupabase;if(window.pakcashConfigError||!sb){location.replace('/login.html?error=config');return null}const s=await window.pakcashGetSession();if(!s){location.replace('/login.html');return null}const {data:p,error}=await sb.from('profiles').select('account_status').eq('id',s.user.id).maybeSingle();if(error||!p){await sb.auth.signOut();location.replace('/login.html?error=profile');return null}if(p.account_status!=='active'){await sb.auth.signOut();location.replace('/login.html?error=account');return null}return s};
window.pakcashSignOut=async function(){if(window.pakcashSupabase)await window.pakcashSupabase.auth.signOut();location.replace('/login.html')};
window.pakcashGetProfile=async function(){const s=await window.pakcashGetSession();if(!s||!window.pakcashSupabase)return null;const {data,error}=await window.pakcashSupabase.from('profiles').select('id,username,referral_code,verified_referrals,account_status,created_at').eq('id',s.user.id).single();return error?null:data};
if(window.pakcashSupabase){window.pakcashSupabase.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT'&&/^(\/|$)/.test(location.pathname)&&document.body?.dataset?.private==='true')location.replace('/login.html')})}
