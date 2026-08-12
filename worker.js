const securityHeaders={
 'X-Content-Type-Options':'nosniff',
 'Referrer-Policy':'strict-origin-when-cross-origin',
 'Permissions-Policy':'geolocation=(), microphone=(), camera=()',
 'X-Frame-Options':'SAMEORIGIN',
 'Content-Security-Policy':"default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; script-src 'self' https://cdn.jsdelivr.net https://*.effectivecpmnetwork.com https://*.highperformanceformat.com; connect-src 'self' https://dmtaynfyhliuttlmystg.supabase.co wss://dmtaynfyhliuttlmystg.supabase.co; img-src 'self' data: blob: https:; style-src 'self'; frame-src 'self' https://*.effectivecpmnetwork.com https://*.highperformanceformat.com; font-src 'self' data:; form-action 'self'"
};
export default {async fetch(request,env){const response=await env.ASSETS.fetch(request);const headers=new Headers(response.headers);for(const [k,v] of Object.entries(securityHeaders))headers.set(k,v);if(new URL(request.url).pathname.match(/\.(?:css|js|svg|png|jpg|jpeg|webp|ico)$/i))headers.set('Cache-Control','public, max-age=86400');else headers.set('Cache-Control','no-store');return new Response(response.body,{status:response.status,statusText:response.statusText,headers})}};
