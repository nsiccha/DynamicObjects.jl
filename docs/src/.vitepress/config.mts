import { defineConfig } from 'vitepress'

export default defineConfig({
  base: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
  title: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
  description: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
  outDir: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
  cleanUrls: true,
  lastUpdated: true,
  markdown: {
    theme: { light: 'github-light', dark: 'github-dark' },
  },
  themeConfig: {
    outline: 'deep',
    search: { provider: 'local' },
    nav: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
    sidebar: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
    editLink: 'REPLACE_ME_DOCUMENTER_VITEPRESS',
    socialLinks: [
      { icon: 'github', link: 'REPLACE_ME_DOCUMENTER_VITEPRESS' },
    ],
  },
})
