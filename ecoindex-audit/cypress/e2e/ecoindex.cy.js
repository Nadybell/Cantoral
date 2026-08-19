describe('Audit EcoIndex — GestOffice', () => {
  it('audite la page réellement connectée (pas l\'écran de connexion)', () => {
    const accessToken = Cypress.env('ACCESS_TOKEN');
    const refreshToken = Cypress.env('REFRESH_TOKEN');
    const targetUrl = Cypress.env('TARGET_URL') || 'https://gestoffices.nadybabs2023.workers.dev';
    const domain = new URL(targetUrl).hostname;

    // Construit la liste de cookies à injecter avant le chargement de la page.
    // Vide si aucun jeton n'est fourni (cas de Cantoral, qui utilise un cookie
    // de rôle simple plutôt qu'une vraie session Supabase).
    const cookies = [];
    if (accessToken && refreshToken) {
      cookies.push({ name: 'ylt_at', value: accessToken, domain, httpOnly: false });
      cookies.push({ name: 'ylt_rt', value: refreshToken, domain, httpOnly: false });
    }
    const roleValue = Cypress.env('ROLE_COOKIE_VALUE');
    if (roleValue) {
      cookies.push({ name: 'ylt_role', value: roleValue, domain, httpOnly: false });
    }

    cy.task('checkEcoIndex', {
      url: targetUrl,
      options: {
        headless: true,
        cookies,
      },
    }).then((result) => {
      cy.writeFile('ecoindex-report.json', result);
      cy.log('Score EcoIndex : ' + JSON.stringify(result.grade || result.score || result));
    });
  });
});
