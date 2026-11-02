-- =====================================================================
-- Índices secundários e chaves estrangeiras, criados APÓS a carga em
-- massa (mais rápido do que manter índices durante o INSERT).
-- =====================================================================
USE nlab_dw;

ALTER TABLE dim_pagina
    ADD KEY idx_pagina_categoria (categoria_nome);

ALTER TABLE fato_revisao
    ADD KEY idx_fato_tempo (sk_tempo),
    ADD KEY idx_fato_hora (sk_hora),
    ADD KEY idx_fato_autor (sk_autor),
    ADD KEY idx_fato_pagina (sk_pagina),
    ADD CONSTRAINT fk_fato_tempo FOREIGN KEY (sk_tempo) REFERENCES dim_tempo(sk_tempo),
    ADD CONSTRAINT fk_fato_hora FOREIGN KEY (sk_hora) REFERENCES dim_hora(sk_hora),
    ADD CONSTRAINT fk_fato_autor FOREIGN KEY (sk_autor) REFERENCES dim_autor(sk_autor),
    ADD CONSTRAINT fk_fato_pagina FOREIGN KEY (sk_pagina) REFERENCES dim_pagina(sk_pagina);

ALTER TABLE fato_referencia
    ADD KEY idx_ref_origem (sk_pagina_origem),
    ADD KEY idx_ref_destino (sk_pagina_destino),
    ADD KEY idx_ref_tipo (sk_tipo_link),
    ADD CONSTRAINT fk_ref_origem FOREIGN KEY (sk_pagina_origem) REFERENCES dim_pagina(sk_pagina),
    ADD CONSTRAINT fk_ref_destino FOREIGN KEY (sk_pagina_destino) REFERENCES dim_pagina(sk_pagina),
    ADD CONSTRAINT fk_ref_tipo FOREIGN KEY (sk_tipo_link) REFERENCES dim_tipo_link(sk_tipo_link);
