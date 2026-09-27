import { defineConfig } from 'vitepress'

// Sovereign Homelab - VitePress site config.
export default defineConfig({
  title: 'Sovereign Homelab',
  description: 'Secure your homelab, secure your node.',


  // GitHub Pages project path: https://twentyonelife.github.io/sovereign-homelab/
  base: '/sovereign-homelab/',


  // Dark cypherpunk brand feel: dark by default, toggle kept.
  appearance: 'dark',
  cleanUrls: true,
  lastUpdated: true,

  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Course', link: '/' },
      { text: 'TwentyOne.Life', link: 'https://twentyone.life' },
      { text: 'GitHub', link: 'https://github.com/TwentyOneLife' }
    ],

    sidebar: [
      {
        text: 'Hack a Network',
        items: [
          { text: '00. Map the Network', link: '/00-network-map' },
          { text: '01. Enumeration', link: '/01-enumeration' },
          { text: '02. Foothold', link: '/02-foothold' },
          { text: '03. Web SQL Injection (DVWA)', link: '/03-web-sqli-dvwa' },
          { text: '04. Web App (Juice Shop)', link: '/04-web-juiceshop' },
          { text: '05. Password Attacks', link: '/05-password-attacks' },
          { text: '06. Linux Privesc and Harden', link: '/06-linux-privesc-blue' },
          { text: '07. Active Directory Recon', link: '/07-ad-recon' },
          { text: '08. AD Escalation', link: '/08-ad-escalation' },
          { text: '09. The Loot (Exfil)', link: '/09-loot-exfil' },
          { text: '10. Wi-Fi (WPA, Simulated)', link: '/10-wifi-wpa' },
          { text: '11. Blue-Team Capstone', link: '/11-blue-capstone' },
          { text: '12. Secure Your Sovereign Node', link: '/12-secure-your-node' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/TwentyOneLife' }
    ],

    search: {
      provider: 'local'
    },

    editLink: {
      pattern: 'https://github.com/TwentyOneLife/sovereign-homelab/edit/main/docs/:path',
      text: 'Edit this page on GitHub'
    },

    footer: {
      message: 'Part of TwentyOne.Life. Support in BitcoinB2B: 1BH665bXvEqSuoWQUihiQiPpt2BqpzrgGD (send from a Bitcoin Blake2b wallet). Nostr/Lightning: TwentyOneLife@primal.net',
      copyright: 'MIT. TwentyOne.Life'
    }
  }
})
