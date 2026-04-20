export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname !== '/' + env.CREATE_PATH) {
      return new Response("Unauthorized Path", { status: 404 });
    }

    if (!env.CF_API_TOKEN || !env.CF_ACCOUNT_ID || !env.CF_ZONE_ID) {
      return new Response("Missing Environment Variables", { status: 500 });
    }

    const timestamp = Math.floor(Date.now() / 1000); 
    const tunnelName = `tunnel-${timestamp}`;

    try {
      const rawSecret = crypto.getRandomValues(new Uint8Array(32));
      const tunnelSecret = btoa(Array.from(rawSecret, b => String.fromCharCode(b)).join(''));

      // 创建隧道
      const createTunnelRes = await fetch(
        `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/tunnels`,
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${env.CF_API_TOKEN}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            name: tunnelName,
            tunnel_secret: tunnelSecret,
          }),
        }
      );

      const tunnelData = await createTunnelRes.json();
      if (!tunnelData.success) {
        return new Response(JSON.stringify(tunnelData), { status: 500 });
      }

      const tunnelId = tunnelData.result.id;
      const tunnelDomain = `${tunnelId}.cfargotunnel.com`;
      const BASE_DOMAIN = env.BASE_DOMAIN;

      // 添加 DNS 记录
      const dnsNames = [
        `${timestamp}.${BASE_DOMAIN}`,
        `${timestamp}-api.${BASE_DOMAIN}`
      ];

      for (const name of dnsNames) {
        await fetch(
          `https://api.cloudflare.com/client/v4/zones/${env.CF_ZONE_ID}/dns_records`,
          {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${env.CF_API_TOKEN}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              type: "CNAME",
              name: name,
              content: tunnelDomain,
              proxied: true,
            }),
          }
        );
      }

      return new Response(JSON.stringify({
        AccountTag: env.CF_ACCOUNT_ID,
        TunnelID: tunnelId,
        TunnelSecret: tunnelSecret,
        domain_name: dnsNames[0],
        domain_name_api: dnsNames[1]
      }, null, 2), {
        headers: { "Content-Type": "application/json" },
      });

    } catch (err) {
      // 捕获具体异常并返回
      return new Response(err.stack, { status: 500 });
    }
  },
};