/*
 * CNI Lava Stroke Engine NPE Fix
 * https://github.com/chushi0/cni-lava-stroke-engine-npe-fix
 *
 * Licensed under the MIT License. See the LICENSE file for details.
 */
package cc.cszt0.cnilavastrokefix;

import net.neoforged.api.distmarker.Dist;
import net.neoforged.bus.api.EventPriority;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.ModContainer;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.client.event.ModelEvent;

/**
 * Client side fix for the {@code NullPointerException} that Create: Nether Industry throws the first
 * time a "Lava Stroke Engine" block is rendered.
 *
 * <p>See {@link CNIPartialsBootstrap} for the root cause and the actual fix. This class just wires it
 * into the mod event bus:
 * <ol>
 *   <li>in the constructor (mod construction happens before any common setup, i.e. before CNI creates
 *       its partial models late),</li>
 *   <li>and at {@link EventPriority#HIGHEST} of {@link ModelEvent.RegisterAdditional}, which runs
 *       before Flywheel's own listener collects {@code PartialModel.ALL} for the bake.</li>
 * </ol>
 */
@Mod(value = LavaStrokeEngineFixMod.MOD_ID, dist = Dist.CLIENT)
public final class LavaStrokeEngineFixMod {

    public static final String MOD_ID = "cni_lavastrokefix";

    public LavaStrokeEngineFixMod(IEventBus modEventBus, ModContainer modContainer) {
        // 1) Earliest possible point in the mod lifecycle.
        CNIPartialsBootstrap.registerPartialsEarly("mod constructor");

        // 2) Belt and braces: whatever the load order was, this runs before Flywheel's listener.
        modEventBus.addListener(EventPriority.HIGHEST, LavaStrokeEngineFixMod::onRegisterAdditional);

        // 3) Diagnostics: prints the post-bake state of the models to logs/latest.log.
        modEventBus.addListener(EventPriority.LOWEST, LavaStrokeEngineFixMod::onBakingCompleted);
    }

    private static void onRegisterAdditional(ModelEvent.RegisterAdditional event) {
        CNIPartialsBootstrap.registerPartialsEarly("ModelEvent.RegisterAdditional");
        CNIPartialsBootstrap.registerModelLocations(event);
    }

    private static void onBakingCompleted(ModelEvent.BakingCompleted event) {
        CNIPartialsBootstrap.reportBakedModels();
    }
}
