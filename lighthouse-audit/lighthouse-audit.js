// Se connecte réellement à GestOffice via Puppeteer (remplissage du formulaire,
// clic), puis lance Lighthouse sur ce même navigateur déjà authentifié.
// Les en-têtes HTTP (--extra-headers) ne créent PAS de vrai cookie navigateur :
// c'est pour ça qu'on pilote Chrome nous-mêmes plutôt que de passer par la CLI seule.

const puppeteer = require('puppeteer');
const lighthouse = require('lighthouse').default || require('lighthouse');
const fs = require('fs');

const TARGET_URL = process.env.TARGET_URL || 'https://gestoffices.nadybabs2023.workers.dev';
const AUDIT_EMAIL = process.env.AUDIT_EMAIL;
const AUDIT_PASSWORD = process.env.AUDIT_PASSWORD;
const ROLE_SELECTOR = process.env.ROLE_SELECTOR; // ex: "#opt-visiteur" pour Cantoral
const OUTPUT_PATH = process.env.OUTPUT_PATH || 'lighthouse-report.json';

(async () => {
  const browser = await puppeteer.launch({
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });

  if (AUDIT_EMAIL && AUDIT_PASSWORD) {
    // Cas GestOffice : vraie connexion via le formulaire email + mot de passe
    const page = await browser.newPage();
    await page.goto(TARGET_URL, { waitUntil: 'networkidle0' });
    await page.type('#auth-email', AUDIT_EMAIL);
    await page.type('#auth-password', AUDIT_PASSWORD);
    await Promise.all([
      page.click('button[onclick="handleSignIn()"]'),
      page.waitForSelector('.role-pill', { timeout: 15000 }),
    ]);
    console.log('Connexion réussie, session active dans le navigateur.');
    await page.close();
  } else if (ROLE_SELECTOR) {
    // Cas Cantoral : simple clic sur un rôle (pas de vraie authentification)
    const page = await browser.newPage();
    await page.goto(TARGET_URL, { waitUntil: 'networkidle0' });
    await page.click(ROLE_SELECTOR);
    await new Promise((resolve) => setTimeout(resolve, 1500));
    console.log('Rôle sélectionné, session active dans le navigateur.');
    await page.close();
  } else {
    console.log("Ni identifiants ni sélecteur de rôle fournis : analyse de la page telle quelle.");
  }

  const { port } = new URL(browser.wsEndpoint());
  const result = await lighthouse(TARGET_URL, {
    port,
    output: 'json',
    onlyCategories: ['performance', 'accessibility', 'best-practices', 'seo'],
  });

  fs.writeFileSync(OUTPUT_PATH, result.report);
  console.log('Rapport enregistré :', OUTPUT_PATH);

  const lhr = result.lhr;
  console.log('=== Scores Lighthouse ===');
  console.log('Performance     :', Math.round(lhr.categories.performance.score * 100));
  console.log('Accessibilité   :', Math.round(lhr.categories.accessibility.score * 100));
  console.log('Bonnes pratiques:', Math.round(lhr.categories['best-practices'].score * 100));
  console.log('SEO             :', Math.round(lhr.categories.seo.score * 100));

  await browser.close();
})().catch((err) => {
  console.error('Erreur pendant l\'audit Lighthouse :', err);
  process.exit(1);
});
