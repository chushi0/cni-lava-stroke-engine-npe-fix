/*
 * CNI Lava Stroke Engine NPE Fix
 * https://github.com/chushi0/cni-lava-stroke-engine-npe-fix
 *
 * Licensed under the MIT License. See the LICENSE file for details.
 */
package cc.cszt0.cnilavastrokefix;

import dev.engine_room.flywheel.lib.model.baked.PartialModel;
import euphy.upo.createnetherindustry.registry.CNIPartials;
import net.minecraft.client.resources.model.BakedModel;
import net.minecraft.client.resources.model.ModelResourceLocation;
import net.minecraft.resources.ResourceLocation;
import net.neoforged.neoforge.client.event.ModelEvent;
import net.neoforged.neoforge.client.model.data.ModelData;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Early registration of the Flywheel {@link PartialModel}s used by Create: Nether Industry's (CNI)
 * "Lava Stroke Engine" block entity renderer.
 *
 * <p><b>Root cause of the crash:</b> CNI builds its partials in the deferred work of
 * {@code FMLCommonSetupEvent} (see {@code CNIPartials.<clinit>}). On NeoForge the client model bake
 * starts before that deferred work runs: {@code ModelEvent.RegisterAdditional} is fired from the
 * {@code ModelBakery} constructor, which happens earlier on a worker thread. Flywheel's
 * {@code PartialModelEventHandler} therefore never sees CNI's partials, and its (unguarded)
 * {@code onBakingCompleted} step leaves {@code PartialModel.bakedModel} as {@code null}. The first
 * time the block is rendered, {@code LavaStrokeEngineRenderer#renderVectorMotionRod} passes that
 * partial to {@code CachedBuffers.partial(...)}, which calls {@code PartialModel#get()} and NPEs.
 *
 * <p><b>Fix:</b> force {@code CNIPartials.<clinit>} to run before Flywheel looks at
 * {@code PartialModel.ALL} - once from our mod constructor (earlier than any common setup) and once
 * more at {@link net.neoforged.bus.api.EventPriority#HIGHEST} of {@code RegisterAdditional}, i.e.
 * before Flywheel's own default-priority listener runs. Flywheel then registers and bakes the
 * partials like any other, so {@code PartialModel#get()} never returns {@code null}.
 */
public final class CNIPartialsBootstrap {

    /** Mod id of Create: Nether Industry. */
    public static final String CNI_MOD_ID = "createnetherindustry";

    /**
     * The same model locations CNI uses ({@code CNIPartials.LAVA_STROKE_ENGINE_ROD/_FLYWHEEL}); kept
     * here as literals so the models can still be registered if the {@code CNIPartials} class itself
     * cannot be loaded (e.g. a future CNI renames its package).
     */
    public static final ResourceLocation ROD_MODEL =
            ResourceLocation.fromNamespaceAndPath(CNI_MOD_ID, "block/lava_stroke_engine/cr1");
    public static final ResourceLocation FLYWHEEL_MODEL =
            ResourceLocation.fromNamespaceAndPath(CNI_MOD_ID, "block/lava_stroke_engine/cr2");

    private static final Logger LOGGER = LoggerFactory.getLogger("CNILavaStrokeEngineFix");

    /**
     * {@code PartialModel.ALL} is a map of <i>weak</i> values, so anything we create ourselves must be
     * held somewhere to keep it alive until Flywheel has baked and stored it.
     */
    private static PartialModel ownRod;
    private static PartialModel ownFlywheel;

    private static boolean partialsRegistered;

    private CNIPartialsBootstrap() {
    }

    /**
     * Makes sure CNI's partial models exist inside Flywheel's {@code PartialModel.ALL} so that they
     * are registered with (and baked by) the model loader. Safe to call multiple times.
     *
     * @param trigger human readable description of the calling site, used for logging only
     */
    public static void registerPartialsEarly(String trigger) {
        if (partialsRegistered) {
            return;
        }

        try {
            // Referencing the class at all triggers CNIPartials.<clinit>, whose field initialisers
            // call PartialModel.of(createnetherindustry:block/lava_stroke_engine/cr1 and cr2).
            CNIPartials.init();
            partialsRegistered = true;
            LOGGER.info("[CNI Lava Stroke Engine Fix] Registered the Lava Stroke Engine partial models"
                    + " through CNIPartials (trigger: {})", trigger);
            return;
        } catch (Throwable t) {
            LOGGER.error("[CNI Lava Stroke Engine Fix] CNIPartials.init() failed (trigger: {});"
                    + " falling back to registering the partial models directly", trigger, t);
        }

        try {
            ownRod = PartialModel.of(ROD_MODEL);
            ownFlywheel = PartialModel.of(FLYWHEEL_MODEL);
            partialsRegistered = true;
            LOGGER.info("[CNI Lava Stroke Engine Fix] Registered the partial models directly: {} and {}",
                    ROD_MODEL, FLYWHEEL_MODEL);
        } catch (Throwable t) {
            LOGGER.error("[CNI Lava Stroke Engine Fix] Could not register the partial models at all;"
                    + " the renderer mixin will keep the game from crashing", t);
        }
    }

    /**
     * Extra safety net: explicitly ask Minecraft to bake the two models, even if Flywheel never
     * registered them (it normally does). {@code register} adds to a set, so this cannot cause
     * duplicate work.
     */
    public static void registerModelLocations(ModelEvent.RegisterAdditional event) {
        event.register(ModelResourceLocation.standalone(ROD_MODEL));
        event.register(ModelResourceLocation.standalone(FLYWHEEL_MODEL));
    }

    /**
     * Logs whether the partial models really ended up with a baked model, so that the fix can be
     * verified from {@code logs/latest.log}.
     */
    public static void reportBakedModels() {
        try {
            BakedModel rod = CNIPartials.LAVA_STROKE_ENGINE_ROD.get();
            BakedModel flywheel = CNIPartials.LAVA_STROKE_ENGINE_FLYWHEEL.get();
            LOGGER.info("[CNI Lava Stroke Engine Fix] Post-bake state of the Lava Stroke Engine models:"
                    + " rod={}, flywheel={}", describe(rod), describe(flywheel));
        } catch (Throwable t) {
            LOGGER.error("[CNI Lava Stroke Engine Fix] Could not read the partial models after the bake", t);
        }
    }

    private static String describe(BakedModel model) {
        if (model == null) {
            return "NOT BAKED (null) - the renderer would crash without the mixin guard";
        }
        try {
            // The no-argument variant is deprecated in NeoForge 21.1 (BakedModel now extends
            // IBakedModelExtension); the ModelData aware overload is the supported API.
            ResourceLocation sprite = model.getParticleIcon(ModelData.EMPTY).contents().name();
            if ("minecraft".equals(sprite.getNamespace()) && "missingno".equals(sprite.getPath())) {
                return "MISSING MODEL (the block assets for this model are broken)";
            }
            return "OK";
        } catch (Throwable t) {
            return "OK";
        }
    }
}
