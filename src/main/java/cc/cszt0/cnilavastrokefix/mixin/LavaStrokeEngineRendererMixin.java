/*
 * CNI Lava Stroke Engine NPE Fix
 * https://github.com/chushi0/cni-lava-stroke-engine-npe-fix
 *
 * Licensed under the MIT License. See the LICENSE file for details.
 */
package cc.cszt0.cnilavastrokefix.mixin;

import com.mojang.blaze3d.vertex.PoseStack;
import dev.engine_room.flywheel.lib.model.baked.PartialModel;
import euphy.upo.createnetherindustry.content.blockentities.LavaStrokeEngineBlockEntity;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.core.Direction;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Safety net on top of {@link cc.cszt0.cnilavastrokefix.CNIPartialsBootstrap}.
 *
 * <p>CNI's renderer hands its {@code PartialModel} to {@code CachedBuffers.partial(...)}, which calls
 * {@code PartialModel#get()}. If that partial was never baked (the situation this fix addresses, or
 * broken/missing block assets), {@code get()} returns {@code null} and the vanilla code NPEs. Instead
 * of crashing, the affected part is simply skipped - the rest of the block still renders.
 *
 * <p>The mixin config is marked {@code "required": false} and the injection uses {@code require = 0},
 * so if CNI ever changes this method the mixin silently does nothing instead of breaking the game.
 */
@Mixin(targets = "euphy.upo.createnetherindustry.client.render.LavaStrokeEngineRenderer", remap = false)
public abstract class LavaStrokeEngineRendererMixin {

    @Inject(method = "renderVectorMotionRod", at = @At("HEAD"), cancellable = true, remap = false, require = 0)
    private void cniLavaStrokeEngineFix$skipUnbakedPart(LavaStrokeEngineBlockEntity blockEntity, BlockState state,
            PartialModel part, PoseStack poseStack, MultiBufferSource buffer, int light, float angleRadians,
            Direction facing, Direction.Axis axis, float phaseOffset, float slantAngleDegrees, float directionMultiplier,
            CallbackInfo callback) {
        if (part == null || part.get() == null) {
            callback.cancel();
        }
    }
}
