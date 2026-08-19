const { defineConfig } = require("cypress");
const { prepareAudit, checkEcoIndex } = require("@cnumr/eco-index-audit/src/cypress");

module.exports = defineConfig({
  e2e: {
    setupNodeEvents(on) {
      // Prépare le navigateur pour permettre à EcoIndex de mesurer la page
      on("before:browser:launch", (_browser, launchOptions) => {
        prepareAudit(launchOptions);
        return launchOptions;
      });

      // Expose la fonction d'audit comme "tâche" utilisable depuis les tests
      on("task", {
        checkEcoIndex: ({ url, options }) => checkEcoIndex({ url, options }),
      });
    },
    // On n'a pas besoin de vraies pages de test HTML, juste du support pour lancer l'audit
    supportFile: false,
  },
});

