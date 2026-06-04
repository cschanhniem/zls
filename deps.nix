{
  linkFarm,
  fetchzip,
  fetchgit,
}:
linkFarm "zig-packages" [
  {
    name = "known_folders-0.0.0-Fy-PJsbKAACbDh9bBxR0MMThxZSS6A9RH4apWphNHY70";
    path = fetchzip {
      url = "https://github.com/ziglibs/known-folders/archive/207c34a16e4365edc20d92c7892f962b3bed46e8.tar.gz";
      hash = "sha256-9hMnEc3ktnFTZT28hjaOkafjSUXEI+SNIO9GMcJrBfA=";
    };
  }
  {
    name = "diffz-0.0.1-G2tlISvOAQDORzPTSxDgiKwlHuADKeJMdJrw4kRfLufj";
    path = fetchzip {
      url = "https://github.com/ziglibs/diffz/archive/aac8aa99c436ab8277b0711922aad062c0167b12.tar.gz";
      hash = "sha256-GQ4iCZSSpVvdDQteoi02keLSqSoDOSQPH8eihum++Z0=";
    };
  }
  {
    name = "lsp_kit-0.1.0-bi_PL1szDADDL-XwGjKQ9lDghQMHspBkeendf1PD7U2a";
    path = fetchzip {
      url = "https://github.com/zigtools/lsp-kit/archive/c3e2ef40986871dbf21a5464fe6858e169c22435.tar.gz";
      hash = "sha256-vuMN/CcV2iyN0SqXVXw356HkyujO83Mp6ZyLV0m3tr4=";
    };
  }
]
